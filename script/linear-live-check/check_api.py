import hashlib
import json
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zlib

ENDPOINT = "https://api.linear.app/graphql"


def main():
    team_id = sys.argv[1]
    log_path = sys.argv[2]
    key = sys.stdin.readline().strip()
    if not key:
        sys.exit("no key on stdin")
    log = open(log_path, "a")

    def say(line):
        print(line)
        log.write(line + "\n")
        log.flush()

    def gql(query, variables=None, mutation_team=None):
        if mutation_team is not None and mutation_team != team_id:
            sys.exit("refusing a mutation outside the test team")
        body = json.dumps({"query": query, "variables": variables or {}}).encode()
        request = urllib.request.Request(ENDPOINT, data=body, headers={"Content-Type": "application/json", "Authorization": key})
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                status, data = response.status, response.read()
        except urllib.error.HTTPError as error:
            status, data = error.code, error.read()
        reply = json.loads(data or b"{}")
        errors = [{"message": str(e.get("message", ""))[:200], "code": (e.get("extensions") or {}).get("code")} for e in reply.get("errors") or []]
        return status, reply.get("data"), errors

    def issue_id(workspace, key_text):
        digest = bytearray(hashlib.sha256((workspace + "\n" + key_text).encode()).digest()[:16])
        digest[6] = (digest[6] & 0x0F) | 0x40
        digest[8] = (digest[8] & 0x3F) | 0x80
        return str(uuid.UUID(bytes=bytes(digest)))

    say(f"== live check {time.strftime('%Y-%m-%dT%H:%M:%S')} (key from stdin, not logged)")
    _, data, errors = gql("query { viewer { id organization { id urlKey } } teams(first: 100) { nodes { id key name } } }")
    if errors or not data:
        sys.exit(f"viewer failed: {errors}")
    workspace = data["viewer"]["organization"]["id"]
    teams = {t["id"]: t for t in data["teams"]["nodes"]}
    if team_id not in teams:
        sys.exit("the test team id is not in this workspace; stopping")
    team = teams[team_id]
    say(f"1 workspace urlKey={data['viewer']['organization']['urlKey']} test team={team['key']} · {team['name']}")

    run_key = f"scout:live-check:{int(time.time())}"
    wanted = issue_id(workspace, run_key)
    say(f"2 key={run_key} derived id={wanted}")

    status, data, errors = gql("query($id: String!) { issue(id: $id) { id } }", {"id": wanted})
    say(f"3 read before create: status={status} data={data} errors={errors}  (Scout maps 'not found' to a miss)")

    png = png_bytes()
    _, data, errors = gql(
        "mutation($ct: String!, $name: String!, $size: Int!) { fileUpload(contentType: $ct, filename: $name, size: $size) { success uploadFile { uploadUrl assetUrl headers { key value } } } }",
        {"ct": "image/png", "name": "pin-1.png", "size": len(png)}, mutation_team=team_id)
    asset_url = None
    if errors or not data:
        say(f"4 fileUpload errors={errors}")
    else:
        upload = data["fileUpload"]["uploadFile"]
        headers = {h["key"]: h["value"] for h in upload["headers"]}
        headers["Content-Type"] = "image/png"
        request = urllib.request.Request(upload["uploadUrl"], data=png, method="PUT", headers=headers)
        with urllib.request.urlopen(request, timeout=60) as response:
            put_status = response.status
        asset_url = upload["assetUrl"]
        host = urllib.parse.urlparse(asset_url).hostname
        upload_host = urllib.parse.urlparse(upload["uploadUrl"]).hostname
        say(f"4 fileUpload ok, PUT status={put_status}, upload host={upload_host}, asset host={host} (Scout expects uploads.linear.app), header keys={sorted(headers)}")

    description = "Live check from Scout's T3 slice.\n\n" + (f"![Pin 1](" + asset_url + ")\n\n" if asset_url else "") + f"---\nFiled from Scout · `{run_key}`"
    create = "mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier url } } }"
    issue_input = {"id": wanted, "teamId": team_id, "title": "Scout live check (safe to delete)", "description": description, "labelIds": [], "priority": 0}
    status, data, errors = gql(create, {"input": issue_input}, mutation_team=team_id)
    created = (data or {}).get("issueCreate") or {}
    accepted = bool(created.get("success")) and (created.get("issue") or {}).get("id") == wanted
    say(f"5 issueCreate with client id: status={status} accepted={accepted} issue={created.get('issue')} errors={errors}")
    if not accepted:
        say("   client ids refused: Scout falls back to the footer marker and searchIssues; record this in the proof")

    target = wanted if accepted else (created.get("issue") or {}).get("id")
    if target:
        _, data, errors = gql("query($id: String!) { issue(id: $id) { id identifier url title priority trashed archivedAt state { name type } labels { nodes { name } } team { key } description } }", {"id": target})
        issue = (data or {}).get("issue") or {}
        say(f"6 read back: identifier={issue.get('identifier')} url={issue.get('url')} team={(issue.get('team') or {}).get('key')} state={issue.get('state')} priority={issue.get('priority')} trashed={issue.get('trashed')} marker_in_description={run_key in (issue.get('description') or '')} image_in_description={bool(asset_url) and asset_url in (issue.get('description') or '')} errors={errors}")

        status, data, errors = gql(create, {"input": issue_input}, mutation_team=team_id)
        say(f"7 resend the same id: status={status} data={data} errors={errors}")

    _, data, errors = gql("query($term: String!, $team: ID!) { searchIssues(term: $term, first: 5, filter: { team: { id: { eq: $team } } }) { nodes { identifier } } }", {"term": run_key, "team": team_id})
    say(f"8 searchIssues for the marker: {data} errors={errors} (expect exactly one issue; search may lag a few seconds)")


def png_bytes():
    raw = b"".join(b"\x00" + bytes([240, 72, 42]) * 8 for _ in range(8))
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 8, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


if __name__ == "__main__":
    main()
