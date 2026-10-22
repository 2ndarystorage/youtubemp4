import json, threading, unittest
from urllib.request import Request, urlopen
from urllib.error import HTTPError
import os, tempfile
_storage = tempfile.TemporaryDirectory()
os.environ['VIDEO_SAVER_DIR'] = _storage.name
import server
from unittest.mock import patch

class Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.http = server.ThreadingHTTPServer(('127.0.0.1', 0), server.Handler)
        cls.base = 'http://127.0.0.1:' + str(cls.http.server_port)
        threading.Thread(target=cls.http.serve_forever, daemon=True).start()
    @classmethod
    def tearDownClass(cls):
        cls.http.shutdown(); cls.http.server_close()
        for job in list(server.JOBS.values()):
            if job.get('title') == 'TEST':
                server.shutil.rmtree(server.DATA / job['id'])
    def test_missing_ssd_does_not_create_directory(self):
        with patch.object(server, 'DATA', server.Path('/Volumes/MissingVideoSaverSSD/YouTubeMP4')):
            with patch.object(server.Path, 'is_mount', return_value=False):
                with patch.object(server.Path, 'mkdir') as mkdir:
                    with self.assertRaises(OSError): server.ensure_storage()
                    mkdir.assert_not_called()

    def test_external_storage_is_created(self):
        with tempfile.TemporaryDirectory() as base:
            target = server.Path(base) / 'SSD' / 'videos'
            with patch.object(server, 'DATA', target):
                self.assertEqual(server.ensure_storage(), target)
                self.assertTrue(target.is_dir())

    def test_busy_port_uses_another_port(self):
        busy = server.ThreadingHTTPServer(('127.0.0.1', 0), server.Handler)
        try:
            fallback = server.create_server(busy.server_port, host='127.0.0.1')
            try:
                self.assertGreater(fallback.server_port, busy.server_port)
                self.assertLess(fallback.server_port, busy.server_port + 10)
                threading.Thread(target=fallback.serve_forever, daemon=True).start()
                with urlopen(f'http://127.0.0.1:{fallback.server_port}/?key={server.TOKEN}') as r:
                    self.assertEqual(r.status, 200)
                fallback.shutdown()
            finally:
                fallback.server_close()
        finally:
            busy.server_close()

    def test_busy_ports_report_clear_error(self):
        busy = server.ThreadingHTTPServer(('127.0.0.1', 0), server.Handler)
        try:
            with self.assertRaises(OSError):
                server.create_server(busy.server_port, host='127.0.0.1', attempts=1)
        finally:
            busy.server_close()
        with self.assertRaises(ValueError):
            server.create_server(70000)

    def test_urls(self):
        for u in ('https://youtu.be/abcdefghijk?t=3', 'https://www.youtube.com/shorts/abcdefghijk', 'https://www.youtube.com/watch?v=abcdefghijk&list=x'):
            self.assertEqual(server.canonical_url(u), 'https://www.youtube.com/watch?v=abcdefghijk')
        for u in ('http://youtu.be/abcdefghijk', 'https://youtube.com.evil.org/watch?v=abcdefghijk', 'https://www.youtube.com/playlist?list=a', 'https://127.0.0.1/a', 'https://youtube.com:80/watch?v=abcdefghijk'):
            with self.assertRaises(ValueError): server.canonical_url(u)
    def test_auth(self):
        with self.assertRaises(HTTPError) as e: urlopen(self.base + '/api/jobs')
        self.assertEqual(e.exception.code, 403)
    def test_job_and_download(self):
        req=Request(self.base+'/api/jobs',data=json.dumps({'url':'https://youtu.be/abcdefghijk','height':720}).encode(),headers={'Content-Type':'application/json','X-Access-Key':server.TOKEN})
        with urlopen(req) as r: job=json.load(r)
        self.assertEqual(job['status'], '待機中')
        current=server.JOBS[job['id']]
        (server.DATA/job['id']/'video.mp4').write_bytes(b'test-mp4')
        server.update(current,title='TEST',status='完了',size=8)
        with urlopen(self.base+'/download/'+job['id']+'?key='+server.TOKEN) as r:
            self.assertEqual(r.headers['Content-Type'],'video/mp4')
            self.assertIn('attachment',r.headers['Content-Disposition'])
            self.assertEqual(r.read(),b'test-mp4')
    def test_page_and_bad_request(self):
        with urlopen(self.base+'/?key='+server.TOKEN) as r: self.assertIn('おうち動画保存',r.read().decode())
        req=Request(self.base+'/api/jobs',data=b'{}',headers={'Content-Type':'application/json','X-Access-Key':server.TOKEN})
        with self.assertRaises(HTTPError) as e: urlopen(req)
        self.assertEqual(e.exception.code,400)

if __name__=='__main__': unittest.main()
