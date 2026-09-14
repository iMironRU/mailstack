#!/usr/bin/env python3
"""Тесты сервиса профилей Apple Mail (profiler).

Код сервиса встроен в mailstack.sh — тест вырезает его оттуда, поднимает
рядом поддельный IMAP-сервер с TLS и поддельный том сертификатов NPM и
гоняет сервис через HTTP так же, как это делает браузер за NPM.

    python3 tests/test_profiler.py

Нужны только python3 и openssl.
"""

import base64
import http.client
import json
import os
import plistlib
import re
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from urllib.parse import urlencode

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "mailstack.sh")

DOMAIN = "test.local"
HOST = "mail.test.local"
USER = "user@test.local"
# Кириллица, кавычка и обратная косая — всё, на чём ломается наивный LOGIN
PASSWORD = 'пароль"с\\подвохом-7Qx'
TTL = 6


def extract_app():
    path = os.environ.get("PROFILER_APP")
    if path:
        with open(path, encoding="utf-8") as f:
            return f.read()
    with open(SCRIPT, encoding="utf-8") as f:
        text = f.read()
    m = re.search(r"<<'PROFILER_APP'\n(.*?)\nPROFILER_APP\n", text, re.S)
    if not m:
        raise SystemExit("в mailstack.sh не найден код profiler (heredoc PROFILER_APP)")
    return m.group(1) + "\n"


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def make_cert(workdir):
    """Самоподписанный сертификат на почтовый хост и localhost,
    разложенный как в томе NPM: live/npm-1 → archive/npm-1."""
    archive = os.path.join(workdir, "le", "archive", "npm-1")
    live = os.path.join(workdir, "le", "live", "npm-1")
    os.makedirs(archive)
    os.makedirs(live)
    cnf = os.path.join(workdir, "req.cnf")
    with open(cnf, "w") as f:
        f.write("[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n"
                "[dn]\nCN=%s\n[ext]\nsubjectAltName=DNS:%s,DNS:localhost\n"
                "basicConstraints=CA:TRUE\n" % (HOST, HOST))
    cert, key = os.path.join(archive, "cert1.pem"), os.path.join(archive, "privkey1.pem")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
                    "-keyout", key, "-out", cert, "-config", cnf],
                   check=True, capture_output=True)
    with open(cert) as src, open(os.path.join(archive, "chain1.pem"), "w") as dst:
        dst.write(src.read())
    for name, target in (("cert.pem", "cert1.pem"), ("privkey.pem", "privkey1.pem"),
                         ("chain.pem", "chain1.pem")):
        os.symlink(os.path.join("..", "..", "archive", "npm-1", target), os.path.join(live, name))
    return cert, key


class FakeIMAP:
    """Ровно столько IMAP, сколько нужно imaplib: приветствие, CAPABILITY,
    AUTHENTICATE PLAIN, LOGOUT. Считает попытки входа."""

    def __init__(self, cert, key, creds):
        self.creds = creds
        self.attempts = 0
        self.ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.ctx.load_cert_chain(cert, key)
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(16)
        self.port = self.sock.getsockname()[1]
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn):
        s = None
        try:
            s = self.ctx.wrap_socket(conn, server_side=True)
            f = s.makefile("rwb")
            f.write(b"* OK fake imap\r\n")
            f.flush()
            while True:
                line = f.readline()
                if not line:
                    break
                parts = line.decode().rstrip("\r\n").split(" ", 2)
                tag, cmd = parts[0], (parts[1] if len(parts) > 1 else "").upper()
                t = tag.encode()
                if cmd == "CAPABILITY":
                    f.write(b"* CAPABILITY IMAP4rev1 AUTH=PLAIN\r\n" + t + b" OK done\r\n")
                elif cmd == "AUTHENTICATE":
                    f.write(b"+ \r\n")
                    f.flush()
                    _, user, pw = base64.b64decode(f.readline().strip()).split(b"\0")
                    self.attempts += 1
                    ok = (user.decode(), pw.decode()) in self.creds
                    f.write(t + (b" OK welcome\r\n" if ok else b" NO [AUTHENTICATIONFAILED] no\r\n"))
                elif cmd == "LOGOUT":
                    f.write(b"* BYE\r\n" + t + b" OK bye\r\n")
                    f.flush()
                    break
                else:
                    f.write(t + b" BAD unsupported\r\n")
                f.flush()
        except Exception:
            pass
        finally:
            try:
                s.close()
            except Exception:
                pass
            conn.close()


def unwrap(data):
    """Содержимое подписанного профиля и признак подписи."""
    if data.lstrip().startswith(b"<?xml"):
        return data, False
    r = subprocess.run(["openssl", "smime", "-verify", "-noverify", "-inform", "der"],
                       input=data, capture_output=True)
    if r.returncode != 0:
        raise AssertionError("подпись не читается: " + r.stderr.decode())
    return r.stdout, True


class Service:
    def __init__(self, workdir, imap_port, le_root, **env):
        self.port = free_port()
        self.log = os.path.join(workdir, "profiler-%d.log" % self.port)
        app = os.path.join(workdir, "app.py")
        if not os.path.exists(app):
            with open(app, "w", encoding="utf-8") as f:
                f.write(extract_app())
        full = dict(os.environ, MAIL_HOSTNAME=HOST, MAIL_DOMAIN=DOMAIN, IMAP_HOST="localhost",
                    IMAP_PORT=str(imap_port), LE_ROOT=le_root, LOG_FILE=self.log,
                    PORT=str(self.port), FAIL_DELAY="0", TOKEN_TTL=str(TTL),
                    SSL_CERT_FILE=os.path.join(workdir, "le", "archive", "npm-1", "cert1.pem"),
                    PYTHONDONTWRITEBYTECODE="1")
        full.update(env)
        self.proc = subprocess.Popen([sys.executable, app], env=full,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for _ in range(100):
            try:
                if self.get("/healthz")[0] == 200:
                    return
            except OSError:
                time.sleep(0.05)
        raise RuntimeError("сервис не поднялся: " + self.proc.stderr.read().decode())

    def stop(self):
        self.proc.terminate()
        self.proc.wait(5)
        self.proc.stderr.close()

    def request(self, method, path, body=None, ip="203.0.113.10"):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        headers = {"X-Real-IP": ip}
        if body is not None:
            body = urlencode(body)
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        c.request(method, path, body=body, headers=headers)
        r = c.getresponse()
        data = r.read()
        c.close()
        return r.status, dict((k.lower(), v) for k, v in r.getheaders()), data

    def get(self, path, ip="203.0.113.10"):
        return self.request("GET", path, ip=ip)

    def post(self, form, ip="203.0.113.10"):
        return self.request("POST", "/setup/apple", form, ip=ip)

    def events(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log, encoding="utf-8") as f:
            return [json.loads(l) for l in f if l.strip()]


class ProfilerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        wd = cls.tmp.name
        cert, key = make_cert(wd)
        cls.imap = FakeIMAP(cert, key, {(USER, PASSWORD), ("other@test.local", "secret-2"),
                                        ("third@test.local", "secret-3")})
        cls.svc = Service(wd, cls.imap.port, os.path.join(wd, "le"))

    @classmethod
    def tearDownClass(cls):
        cls.svc.stop()
        cls.tmp.cleanup()

    def issue(self, device="ios", email=USER, name="Иван Петров", password=PASSWORD, ip="203.0.113.10"):
        form = {"device": device, "email": email, "name": name}
        if password is not None:
            form["password"] = password
        status, headers, _ = self.svc.post(form, ip=ip)
        self.assertEqual(status, 303, "профиль не выдан")
        token = headers["location"].rsplit("/", 1)[1]
        return token

    # ── основной путь ────────────────────────────────────────────────────────

    def test_form_page(self):
        status, headers, body = self.svc.get("/setup/apple")
        self.assertEqual(status, 200)
        self.assertIn("frame-ancestors 'none'", headers["content-security-policy"])
        self.assertIn(b'name="password"', body)
        self.assertEqual(body.count(b"<form"), 2, "нужны две формы: iPhone и Mac")

    def test_ios_profile_contains_everything(self):
        token = self.issue()
        status, _, body = self.svc.get("/setup/apple/ready/" + token)
        self.assertEqual(status, 200)
        self.assertIn(("/setup/apple/p/%s.mobileconfig" % token).encode(), body)

        status, headers, data = self.svc.get("/setup/apple/p/%s.mobileconfig" % token)
        self.assertEqual(status, 200)
        self.assertEqual(headers["content-type"], "application/x-apple-aspen-config")
        self.assertEqual(headers["cache-control"], "no-store")
        xml, signed = unwrap(data)
        self.assertTrue(signed, "профиль должен быть подписан")
        acc = plistlib.loads(xml)["PayloadContent"][0]
        self.assertEqual(acc["EmailAddress"], USER)
        self.assertEqual(acc["IncomingMailServerUsername"], USER)
        self.assertEqual(acc["OutgoingMailServerUsername"], USER)
        self.assertEqual(acc["IncomingPassword"], PASSWORD)
        self.assertEqual(acc["OutgoingPassword"], PASSWORD)
        self.assertEqual(acc["EmailAccountName"], "Иван Петров")
        self.assertEqual(acc["IncomingMailServerHostName"], HOST)

    def test_mac_profile_has_no_password(self):
        token = self.issue(device="mac", password="это не должно попасть в профиль")
        _, _, data = self.svc.get("/setup/apple/p/%s.mobileconfig" % token)
        acc = plistlib.loads(unwrap(data)[0])["PayloadContent"][0]
        self.assertEqual(acc["EmailAddress"], USER)
        self.assertNotIn("IncomingPassword", acc)
        self.assertNotIn("OutgoingPassword", acc)
        self.assertNotIn("это не должно".encode(), data)

    def test_mac_does_not_touch_imap(self):
        before = self.imap.attempts
        self.issue(device="mac", password=None, ip="203.0.113.60")
        self.assertEqual(self.imap.attempts, before)

    def test_generic_profile(self):
        status, headers, data = self.svc.get("/setup/mail.mobileconfig")
        self.assertEqual(status, 200)
        self.assertEqual(headers["content-type"], "application/x-apple-aspen-config")
        xml, signed = unwrap(data)
        self.assertTrue(signed)
        profile = plistlib.loads(xml)
        acc = profile["PayloadContent"][0]
        self.assertEqual(acc["EmailAddress"], "")
        self.assertNotIn("IncomingPassword", acc)
        self.assertEqual(profile["PayloadIdentifier"], "local.test.mailstack")

    def test_personal_identifiers_differ_per_mailbox(self):
        a = self.issue(ip="203.0.113.70")
        # отдельный ящик: other@ соседний тест доводит до лимита
        b = self.issue(email="third@test.local", password="secret-3", ip="203.0.113.70")
        pa = plistlib.loads(unwrap(self.svc.get("/setup/apple/p/%s.mobileconfig" % a, ip="203.0.113.70")[2])[0])
        pb = plistlib.loads(unwrap(self.svc.get("/setup/apple/p/%s.mobileconfig" % b, ip="203.0.113.70")[2])[0])
        self.assertNotEqual(pa["PayloadIdentifier"], pb["PayloadIdentifier"],
                            "два ящика на одном iPhone не должны заменять друг друга")

    # ── одноразовая ссылка ───────────────────────────────────────────────────

    def test_link_is_bound_to_first_ip(self):
        token = self.issue(ip="203.0.113.20")
        path = "/setup/apple/p/%s.mobileconfig" % token
        self.assertEqual(self.svc.get(path, ip="203.0.113.20")[0], 200)
        self.assertEqual(self.svc.get(path, ip="198.51.100.99")[0], 410)

    def test_link_download_limit(self):
        token = self.issue(ip="203.0.113.21")
        path = "/setup/apple/p/%s.mobileconfig" % token
        codes = [self.svc.get(path, ip="203.0.113.21")[0] for _ in range(5)]
        self.assertEqual(codes, [200, 200, 200, 410, 410])

    def test_head_does_not_consume(self):
        token = self.issue(ip="203.0.113.22")
        path = "/setup/apple/p/%s.mobileconfig" % token
        for _ in range(5):
            self.assertEqual(self.svc.request("HEAD", path, ip="203.0.113.22")[0], 200)
        self.assertEqual(self.svc.get(path, ip="203.0.113.22")[0], 200)

    def test_link_expires(self):
        token = self.issue(ip="203.0.113.23")
        time.sleep(TTL + 1)
        self.assertEqual(self.svc.get("/setup/apple/p/%s.mobileconfig" % token, ip="203.0.113.23")[0], 410)
        self.assertEqual(self.svc.get("/setup/apple/ready/" + token, ip="203.0.113.23")[0], 410)

    def test_bogus_tokens(self):
        for t in ("../../etc/passwd", "x" * 32, "A" * 200):
            self.assertIn(self.svc.get("/setup/apple/p/%s.mobileconfig" % t)[0], (404, 410))

    # ── проверки формы ───────────────────────────────────────────────────────

    def test_wrong_password(self):
        before = self.imap.attempts
        status, _, body = self.svc.post({"device": "ios", "email": USER, "name": "X",
                                         "password": "неверный"}, ip="203.0.113.30")
        self.assertEqual(status, 403)
        self.assertIn("не подходят".encode(), body)
        self.assertEqual(self.imap.attempts, before + 1)

    def test_foreign_domain_rejected_before_imap(self):
        before = self.imap.attempts
        status, _, body = self.svc.post({"device": "ios", "email": "user@evil.example",
                                         "name": "X", "password": "x"}, ip="203.0.113.31")
        self.assertEqual(status, 400)
        self.assertEqual(self.imap.attempts, before)

    def test_name_cannot_inject_plist_keys(self):
        evil = "</string><key>IncomingMailServerHostName</key><string>evil.example"
        token = self.issue(device="mac", name=evil, password=None, ip="203.0.113.32")
        _, _, data = self.svc.get("/setup/apple/p/%s.mobileconfig" % token, ip="203.0.113.32")
        acc = plistlib.loads(unwrap(data)[0])["PayloadContent"][0]
        self.assertEqual(acc["IncomingMailServerHostName"], HOST)
        # разметка осталась текстом внутри имени, а не стала ключами
        self.assertTrue(acc["EmailAccountName"].startswith("</string><key>"))
        self.assertLessEqual(len(acc["EmailAccountName"]), 64)

    def test_form_keeps_values_but_never_password(self):
        status, _, body = self.svc.post({"device": "ios", "email": USER, "name": "Мария",
                                         "password": "неверный-пароль-123"}, ip="203.0.113.33")
        self.assertEqual(status, 403)
        self.assertIn(USER.encode(), body)
        self.assertIn("Мария".encode(), body)
        self.assertNotIn("неверный-пароль-123".encode(), body)

    # ── лимиты ───────────────────────────────────────────────────────────────

    def test_ip_rate_limit_stops_before_imap(self):
        ip = "203.0.113.40"
        for _ in range(5):
            self.assertEqual(self.svc.post({"device": "ios", "email": USER, "name": "X",
                                            "password": "bad"}, ip=ip)[0], 403)
        before = self.imap.attempts
        status, _, _ = self.svc.post({"device": "ios", "email": USER, "name": "X",
                                      "password": PASSWORD}, ip=ip)
        self.assertEqual(status, 429, "даже верный пароль после лимита не проверяется")
        self.assertEqual(self.imap.attempts, before)

    def test_mailbox_rate_limit_across_ips(self):
        mailbox = "other@test.local"
        for i in range(10):
            self.assertEqual(self.svc.post({"device": "ios", "email": mailbox, "name": "X",
                                            "password": "bad"}, ip="198.51.100.%d" % i)[0], 403)
        before = self.imap.attempts
        status, _, _ = self.svc.post({"device": "ios", "email": mailbox, "name": "X",
                                      "password": "secret-2"}, ip="198.51.100.200")
        self.assertEqual(status, 429)
        self.assertEqual(self.imap.attempts, before)

    # ── журнал ───────────────────────────────────────────────────────────────

    def test_zz_log_has_no_secrets(self):
        # zz — выполняется последним, когда журнал уже наполнен
        with open(self.svc.log, encoding="utf-8") as f:
            raw = f.read()
        self.assertTrue(raw, "журнал пуст")
        for secret in (PASSWORD, "secret-2", "secret-3", "неверный", "неверный-пароль-123"):
            self.assertNotIn(secret, raw, "в журнале пароль")
        self.assertNotRegex(raw, r"[A-Za-z0-9_-]{32}", "в журнале токен ссылки")
        events = {e["event"] for e in self.svc.events()}
        for needed in ("issued", "download", "auth_fail", "rate_limited", "download_denied"):
            self.assertIn(needed, events)
        fails = [e for e in self.svc.events() if e["event"] == "auth_fail"]
        self.assertTrue(all(set(e) == {"ts", "event", "ip", "email"} for e in fails))


class UnsignedFallbackTest(unittest.TestCase):
    def test_serves_unsigned_without_certificate(self):
        with tempfile.TemporaryDirectory() as wd:
            cert, key = make_cert(wd)
            imap = FakeIMAP(cert, key, {(USER, PASSWORD)})
            svc = Service(wd, imap.port, os.path.join(wd, "no-such-le"))
            try:
                status, _, data = svc.get("/setup/mail.mobileconfig")
                self.assertEqual(status, 200)
                xml, signed = unwrap(data)
                self.assertFalse(signed)
                plistlib.loads(xml)
                self.assertIn("sign_skipped", {e["event"] for e in svc.events()})
            finally:
                svc.stop()


if __name__ == "__main__":
    unittest.main(verbosity=2)
