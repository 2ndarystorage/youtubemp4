import json, threading, unittest
from urllib.request import Request, urlopen
from urllib.error import HTTPError
import server

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
