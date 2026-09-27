#!/usr/bin/env python3
"""Live access test. Set ALFRESCO_PASSWORD; optionally ALFRESCO_URL (LAN HTTP)."""
import base64
import http.cookiejar
import json
import os
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("ALFRESCO_URL", "http://alfresco.local").rstrip("/")
PASSWORD = os.environ["ALFRESCO_PASSWORD"]
API = "/alfresco/api/-default-/public/alfresco/versions/1"
AUTH = "/alfresco/api/-default-/public/authentication/versions/1/tickets"
SEARCH = "/alfresco/api/-default-/public/search/versions/1/search"
ADMIN = ("admin", PASSWORD)


def request(path, method="GET", data=None, auth=ADMIN, expected=200, content_type=None):
    headers = {}
    if auth:
        headers["Authorization"] = "Basic " + base64.b64encode(
            (auth if isinstance(auth, str) else ":".join(auth)).encode()
        ).decode()
    if isinstance(data, dict):
        data = json.dumps(data).encode()
        content_type = "application/json"
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(BASE + path, data, headers, method=method)
    try:
        response = urllib.request.urlopen(req, timeout=60)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        body = response.read()
        assert response.status == expected, (method, path, response.status, body[:500])
        if "application/json" in response.headers.get("Content-Type", "") and body:
            return json.loads(body)
        return body


def main():
    request(API + "/nodes/-my-", auth=None, expected=401)
    request(AUTH, "POST", {"userId": "admin", "password": "wrong"}, auth=None, expected=403)
    request(AUTH, "POST", {"userId": "admin", "password": "admin"}, auth=None, expected=403)
    ticket = request(AUTH, "POST", {"userId": "admin", "password": PASSWORD},
                     auth=None, expected=201)["entry"]["id"]
    request(AUTH + "/-me-", auth=ticket)
    print("PASS authentication; anonymous, wrong and factory-default passwords rejected")

    cookies = http.cookiejar.CookieJar()
    browser = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookies))
    with browser.open(BASE + "/share/page/", timeout=60) as response:
        assert b"username" in response.read()
    form = urllib.parse.urlencode({"username": "admin", "password": PASSWORD}).encode()
    with browser.open(BASE + "/share/page/dologin", form, timeout=60) as response:
        page = response.read()
        assert "/user/admin/dashboard" in response.url, response.url
        assert b"logout" in page.lower(), "Share did not establish a logged-in session"
    request("/api-explorer/", auth=None)
    print("PASS Share form login, authenticated dashboard and API Explorer")

    suffix = secrets.token_hex(6)
    reader = ("smoke-" + suffix, secrets.token_hex(24))
    folder = None
    user_created = False
    try:
        request(API + "/people", "POST", {
            "id": reader[0], "firstName": "Smoke", "lastName": "Reader",
            "email": reader[0] + "@example.invalid", "password": reader[1],
        }, expected=201)
        user_created = True
        folder = request(API + "/nodes/-my-/children", "POST", {
            "name": "smoke-" + suffix, "nodeType": "cm:folder",
            "permissions": {"isInheritanceEnabled": False},
        }, expected=201)["entry"]["id"]
        request(API + "/nodes/" + folder, auth=reader, expected=403)
        request(API + "/nodes/" + folder, "PUT", {
            "permissions": {"isInheritanceEnabled": False, "locallySet": [
                {"authorityId": reader[0], "name": "Consumer", "accessStatus": "ALLOWED"}
            ]}
        })
        # Multipart upload exercises the same content endpoint used by clients.
        name = "alfresco-smoke-" + suffix + ".txt"
        content = ("Alfresco k3s document access test " + suffix + "\n").encode()
        boundary = "----alfresco" + suffix
        multipart = (f"--{boundary}\r\nContent-Disposition: form-data; "
                     f'name="filedata"; filename="{name}"\r\n'
                     "Content-Type: text/plain\r\n\r\n").encode()
        multipart += content + f"\r\n--{boundary}--\r\n".encode()
        node = request(API + f"/nodes/{folder}/children", "POST", multipart,
                       expected=201, content_type="multipart/form-data; boundary=" + boundary)["entry"]["id"]
        assert request(API + f"/nodes/{node}/content") == content
        assert request(API + f"/nodes/{node}/content", auth=reader) == content
        request(API + f"/nodes/{node}/content", "PUT", b"forbidden edit", auth=reader,
                expected=403, content_type="text/plain")
        request(API + f"/nodes/{node}", "DELETE", auth=reader, expected=403)
        assert request(API + f"/nodes/{node}/content") == content
        print("PASS upload/download byte comparison; Consumer can read, cannot edit/delete")

        updated = content + b"Updated document version\n"
        request(API + f"/nodes/{node}/content", "PUT", updated, content_type="text/plain")
        assert request(API + f"/nodes/{node}/content") == updated
        versions = request(API + f"/nodes/{node}/versions")["list"]["entries"]
        assert len(versions) >= 2, versions
        print("PASS content update and version history")

        request(API + f"/nodes/{node}/renditions", "POST", {"id": "pdf"}, expected=202)
        for _ in range(60):
            if request(API + f"/nodes/{node}/renditions/pdf")["entry"]["status"] == "CREATED":
                break
            time.sleep(3)
        else:
            raise AssertionError("PDF preview not generated after 180 seconds")
        assert request(API + f"/nodes/{node}/renditions/pdf/content").startswith(b"%PDF")
        print("PASS PDF preview transformation")

        for _ in range(60):
            results = request(SEARCH, "POST", {
                "query": {"language": "afts", "query": f'TEXT:"{suffix}"'},
                "include": ["properties"],
            })
            if any(item["entry"]["id"] == node for item in results["list"]["entries"]):
                break
            time.sleep(5)
        else:
            raise AssertionError("Uploaded content not searchable after 300 seconds")
        print("PASS full-text search of uploaded content")
    finally:
        if folder:
            request(API + f"/nodes/{folder}?permanent=true", "DELETE", expected=204)
        if user_created:
            # The public v1 API has no person-delete operation.
            request("/alfresco/s/api/people/" + reader[0], "DELETE")
        request(AUTH + "/-me-", "DELETE", auth=ticket, expected=204)
    request(AUTH + "/-me-", auth=ticket, expected=401)
    print("PASS cleanup and ticket revocation")


if __name__ == "__main__":
    main()
