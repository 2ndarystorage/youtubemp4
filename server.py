#!/usr/bin/env python3
import errno
import json, os, queue, re, secrets, shutil, socket, subprocess, threading, uuid
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parent
DATA = Path(os.environ.get('VIDEO_SAVER_DIR', '/Volumes/M2NVMe/YouTubeMP4')).expanduser().absolute()

def ensure_storage():
    # /Volumes直下のマウントが消えたとき、内蔵ドライブへ代替保存しない。
    if DATA.parts[:2] == ('/', 'Volumes'):
        if len(DATA.parts) < 4:
            raise OSError('保存先には外付けSSD内のフォルダーを指定してください')
        volume = Path(*DATA.parts[:3])
        if not volume.is_mount() or volume.is_symlink():
            raise OSError(f'外付けSSDが接続されていません: {volume}')
        if not DATA.resolve().is_relative_to(volume.resolve()):
            raise OSError('保存先が指定のSSDの外を指しています')
    DATA.mkdir(parents=True, exist_ok=True)
    if DATA.parts[:2] == ('/', 'Volumes') and DATA.stat().st_dev != volume.stat().st_dev:
        raise OSError('保存先が指定のSSDと異なるドライブにあります')
    return DATA

try:
    ensure_storage()
except OSError as exc:
    raise SystemExit(f'保存先を使用できません: {exc}') from exc
TOKEN = secrets.token_urlsafe(24)
JOBS = {}
LOCK = threading.RLock()
QUEUE = queue.Queue(maxsize=20)

def canonical_url(value):
    p = urlsplit(value.strip())
    if p.scheme != 'https' or p.username or p.password or p.port not in (None, 443):
        raise ValueError('httpsのYouTube動画URLを入力してください')
    if p.hostname in ('youtu.be', 'www.youtu.be'):
        vid = p.path.strip('/')
    elif p.hostname in ('youtube.com', 'www.youtube.com', 'm.youtube.com'):
        if p.path == '/watch':
            vid = parse_qs(p.query).get('v', [''])[0]
        elif p.path.startswith(('/shorts/', '/live/')):
            vid = p.path.split('/')[2]
        else:
            vid = ''
    else:
        vid = ''
    if not re.fullmatch(r'[A-Za-z0-9_-]{11}', vid):
        raise ValueError('単体のYouTube動画URLを入力してください')
    return 'https://www.youtube.com/watch?v=' + vid

def update(job, **values):
    with LOCK:
        job.update(values)
        ensure_storage()
        target = DATA / job['id'] / 'job.json'
        tmp = target.with_suffix('.tmp')
        tmp.write_text(json.dumps(job, ensure_ascii=False))
        tmp.replace(target)

def worker():
    while True:
        job = QUEUE.get()
        directory = DATA / job['id']
        try:
            ensure_storage()
            if shutil.disk_usage(DATA).free < 3 * 1024**3:
                raise RuntimeError(f'保存先の空き容量が3GiB未満です: {DATA}')
            update(job, status='取得中', progress='接続しています')
            h = job['height']
            cmd = ['yt-dlp', '--ignore-config', '--no-playlist', '--no-colors', '--newline',
                   '--socket-timeout', '30', '--retries', '3', '--max-filesize', '2G',
                   '--match-filters', '!is_live & duration <= 7200',
                   '-f', f'bv[ext=mp4][vcodec^=avc1][height<={h}]+ba[ext=m4a]/b[ext=mp4][vcodec^=avc1][height<={h}]',
                   '--merge-output-format', 'mp4', '--write-info-json',
                   '-o', str(directory / 'video.%(ext)s'),
                   '--progress-template', 'download:進捗 %(progress._percent_str)s / %(progress._eta_str)s',
                   '--', job['url']]
            with (directory / 'process.log').open('w') as log:
                p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                tail = []
                for line in p.stdout:
                    log.write(line); log.flush()
                    tail = (tail + [line.strip()])[-6:]
                    update(job, progress=line.strip()[-350:])
                if p.wait() != 0:
                    raise RuntimeError('\n'.join(tail))
            file = directory / 'video.mp4'
            if not file.is_file():
                raise RuntimeError('対応するMP4が取得できませんでした')
            info = json.loads((directory / 'video.info.json').read_text())
            update(job, status='完了', progress='保存できます', title=info.get('title', '動画'), size=file.stat().st_size)
        except Exception as e:
            try:
                update(job, status='失敗', progress=str(e)[-1200:])
            except OSError:
                # SSD切断時もメモリー内に失敗理由を残し、ワーカーを継続する。
                with LOCK:
                    job.update(status='失敗', progress=str(e)[-1200:])
        finally:
            QUEUE.task_done()

for metadata in DATA.glob('*/job.json'):
    try:
        job = json.loads(metadata.read_text())
        if job['status'] not in ('完了', '失敗'):
            job.update(status='失敗', progress='前回の終了で中断しました。再登録してください')
        JOBS[job['id']] = job
    except (ValueError, KeyError):
        pass

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # URL内の接続キーをログに記録しない

    def reply(self, code, data, content='application/json; charset=utf-8'):
        body = data if isinstance(data, bytes) else json.dumps(data, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', content)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        key = self.headers.get('X-Access-Key') or parse_qs(urlsplit(self.path).query).get('key', [''])[0]
        return secrets.compare_digest(key, TOKEN)

    def do_GET(self):
        if not self.authorized():
            return self.reply(403, {'error': '起動時に表示された接続URLで開いてください'})
        path = urlsplit(self.path).path
        if path == '/':
            return self.reply(200, (ROOT / 'index.html').read_bytes(), 'text/html; charset=utf-8')
        if path == '/api/jobs':
            with LOCK:
                return self.reply(200, list(JOBS.values())[::-1])
        match = re.fullmatch(r'/download/([0-9a-f]{32})', path)
        if match:
            with LOCK:
                job = JOBS.get(match[1], {}).copy()
            file = DATA / match[1] / 'video.mp4'
            if job.get('status') != '完了' or not file.is_file():
                return self.reply(404, {'error': 'ファイルがありません'})
            self.send_response(200)
            self.send_header('Content-Type', 'video/mp4')
            self.send_header('Content-Disposition', f'attachment; filename="video-{match[1][:8]}.mp4"')
            self.send_header('Content-Length', str(file.stat().st_size))
            self.send_header('Referrer-Policy', 'no-referrer')
            self.end_headers()
            try:
                with file.open('rb') as f:
                    shutil.copyfileobj(f, self.wfile)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        self.reply(404, {'error': '見つかりません'})

    def do_POST(self):
        if not self.authorized():
            return self.reply(403, {'error': '接続キーが無効です'})
        # JSONと独自ヘッダーを必須とし、他サイトからのフォーム送信を受け付けない
        if self.headers.get('Content-Type') != 'application/json' or not self.headers.get('X-Access-Key'):
            return self.reply(415, {'error': 'JSONで送信してください'})
        if urlsplit(self.path).path != '/api/jobs':
            return self.reply(404, {'error': '見つかりません'})
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length <= 4096:
                raise ValueError('リクエストサイズが不正です')
            data = json.loads(self.rfile.read(length))
            url = canonical_url(data['url'])
            height = int(data.get('height', 720))
            if height not in (360, 720, 1080):
                raise ValueError('画質が不正です')
            ensure_storage()
            with LOCK:
                if QUEUE.full():
                    return self.reply(429, {'error': '待機件数が上限です'})
                job = dict(id=uuid.uuid4().hex, url=url, height=height, title=url, status='待機中', progress='順番待ち')
                (DATA / job['id']).mkdir()
                JOBS[job['id']] = job
                update(job)
                QUEUE.put_nowait(job)
            self.reply(201, job)
        except (ValueError, KeyError, TypeError) as e:
            self.reply(400, {'error': str(e)})
        except OSError as e:
            self.reply(503, {'error': f'保存先を使用できません: {e}'})

def create_server(port=8765, host='0.0.0.0', attempts=10):
    if not 1 <= port <= 65535:
        raise ValueError('VIDEO_SAVER_PORTは1〜65535で指定してください')
    for candidate in range(port, min(port + attempts, 65536)):
        try:
            return ThreadingHTTPServer((host, candidate), Handler)
        except OSError as exc:
            if exc.errno != errno.EADDRINUSE:
                raise
    raise OSError(errno.EADDRINUSE, f'{port}番からの候補ポートがすべて使用中です。VIDEO_SAVER_PORTで別の番号を指定してください')

if __name__ == '__main__':
    for binary in ('yt-dlp', 'ffmpeg', 'deno'):
        if not shutil.which(binary):
            raise SystemExit(f'{binary}がありません。setup.commandを実行してください')
    print(f'保存先: {DATA}', flush=True)
    print(f'保存先の空き容量: {shutil.disk_usage(DATA).free / 1024**3:.1f} GiB', flush=True)
    try:
        requested_port = int(os.environ.get('VIDEO_SAVER_PORT', '8765'))
        server = create_server(requested_port)
    except (ValueError, OSError) as exc:
        raise SystemExit(f'起動できません: {exc}') from exc
    actual_port = server.server_port
    if actual_port != requested_port:
        print(f'{requested_port}番は使用中のため、{actual_port}番で起動します。', flush=True)
    threading.Thread(target=worker, daemon=True).start()
    print('\n同じWi-FiのiPhoneで、次のURLを開いてください（接続キー付き）', flush=True)
    addresses = {'127.0.0.1'}
    try:
        result = subprocess.run(['ifconfig'], capture_output=True, text=True, check=True)
        addresses.update(re.findall(r'inet (\d+\.\d+\.\d+\.\d+)', result.stdout))
    except (OSError, subprocess.SubprocessError):
        pass
    for ip in sorted(addresses):
        print(f'http://{ip}:{actual_port}/?key={TOKEN}', flush=True)
    print('停止: Control+C。再起動すると接続キーが変わります。', flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
