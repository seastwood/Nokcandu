import socket
import threading
import unittest
from query import query


class QueryTests(unittest.TestCase):
    def testExactQueryAndReplyToSourceSocket(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
            server.bind(('127.0.0.1', 0))
            server.settimeout(2)
            received = []
            def answer():
                data, peer = server.recvfrom(1024)
                received.append(data)
                server.sendto(b'\\hostname\\test\\final\\', peer)
            worker = threading.Thread(target=answer)
            worker.start()
            result = query('127.0.0.1', [server.getsockname()[1]], .5)
            worker.join(2)
            self.assertEqual(received, [b'\\status\\'])
            self.assertEqual(result, [(server.getsockname(), 21)])

    def testTimeoutReturnsNoReplies(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as silent:
            silent.bind(('127.0.0.1', 0))
            self.assertEqual(query('127.0.0.1', [silent.getsockname()[1]], .1), [])


if __name__ == '__main__':
    unittest.main()
