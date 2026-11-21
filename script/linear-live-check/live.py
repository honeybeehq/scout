import hashlib
import json
import os
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zlib

ENDPOINT = "https://api.linear.app/graphql"


TITLE_PREFIX = "[scout-test] "


def main():
    command, team_id, out = sys.argv[1], sys.argv[2], sys.argv[3]
    key = sys.stdin.readline().strip()
    if not key:
        sys.exit("no key on stdin")
    if command == "check":
        check(key, team_id, out, sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None)
    elif command == "video-verify":
        video_verify(key, team_id, out)
    elif command == "cleanup":
        cleanup(key, team_id, out)
    else:
        sys.exit("usage: <key on stdin> live.py check|video-verify|cleanup <team id> <out dir> [clip.mp4]")


def client(key, team_id):
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
    return gql


def logger(path):
    log = open(path, "a")

    def say(line):
        print(line)
        log.write(line + "\n")
        log.flush()
    return say


def check(key, team_id, out, clip_path=None):
    say = logger(os.path.join(out, "api.log"))
    gql = client(key, team_id)
    created_file = open(os.path.join(out, "created-ids.txt"), "a")

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
    issue_input = {"id": wanted, "teamId": team_id, "title": TITLE_PREFIX + "Scout live check", "description": description, "labelIds": [], "priority": 0}
    status, data, errors = gql(create, {"input": issue_input}, mutation_team=team_id)
    created = (data or {}).get("issueCreate") or {}
    accepted = bool(created.get("success")) and (created.get("issue") or {}).get("id") == wanted
    say(f"5 issueCreate with client id: status={status} accepted={accepted} issue={created.get('issue')} errors={errors}")
    if not accepted:
        say("   client ids refused: Scout falls back to the footer marker and searchIssues; record this in the proof")

    target = wanted if accepted else (created.get("issue") or {}).get("id")
    if target:
        created_file.write(target + "\n")
        created_file.flush()
        _, data, errors = gql("query($id: String!) { issue(id: $id) { id identifier url title priority trashed archivedAt state { name type } labels { nodes { name } } team { key } description } }", {"id": target})
        issue = (data or {}).get("issue") or {}
        say(f"6 read back: identifier={issue.get('identifier')} url={issue.get('url')} team={(issue.get('team') or {}).get('key')} state={issue.get('state')} priority={issue.get('priority')} trashed={issue.get('trashed')} marker_in_description={run_key in (issue.get('description') or '')} image_in_description={bool(asset_url) and asset_url in (issue.get('description') or '')} errors={errors}")

        status, data, errors = gql(create, {"input": issue_input}, mutation_team=team_id)
        say(f"7 resend the same id: status={status} data={data} errors={errors}")
        duplicate = (((data or {}).get("issueCreate") or {}).get("issue") or {}).get("id")
        if duplicate and duplicate != target:
            created_file.write(duplicate + "\n")
            created_file.flush()
            say(f"   DUPLICATE created by the resend: {duplicate}")

    _, data, errors = gql("query($term: String!, $team: ID!) { searchIssues(term: $term, first: 5, filter: { team: { id: { eq: $team } } }) { nodes { identifier } } }", {"term": run_key, "team": team_id})
    say(f"8 searchIssues for the marker: {data} errors={errors} (expect exactly one issue; search may lag a few seconds)")

    if target:
        check_video(gql, say, team_id, workspace, run_key, target, clip_path)


def check_video(gql, say, team_id, workspace, run_key, issue_id_value, clip_path):
    upload = "mutation($ct: String!, $name: String!, $size: Int!) { fileUpload(contentType: $ct, filename: $name, size: $size) { success uploadFile { uploadUrl assetUrl headers { key value } } } }"
    say("9 video size limit: fileUpload requests only, no bytes are sent")
    for megabytes in [10, 50, 100, 200, 500, 1024, 2048, 4096]:
        size = megabytes * 1024 * 1024
        _, data, errors = gql(upload, {"ct": "video/mp4", "name": "clip.mp4", "size": size}, mutation_team=team_id)
        reply = (data or {}).get("fileUpload") or {}
        headers = {h["key"]: h["value"] for h in ((reply.get("uploadFile") or {}).get("headers") or [])}
        ranges = {k: v for k, v in headers.items() if "length" in k.lower() or "range" in k.lower()}
        say(f"   {megabytes:>5} MB: success={reply.get('success')} errors={errors} length headers={ranges}")
        if errors or not reply.get("success"):
            say(f"   first refused size: {megabytes} MB (Scout maps this to 'The video is too big for Linear')")
            break

    if not clip_path:
        say("10 attachment shape: skipped, no clip path given")
        return
    clip = open(clip_path, "rb").read()
    _, data, errors = gql(upload, {"ct": "video/mp4", "name": "clip.mp4", "size": len(clip)}, mutation_team=team_id)
    if errors or not data:
        say(f"10 clip fileUpload errors={errors}")
        return
    target = data["fileUpload"]["uploadFile"]
    headers = {h["key"]: h["value"] for h in target["headers"]}
    headers["Content-Type"] = "video/mp4"
    request = urllib.request.Request(target["uploadUrl"], data=clip, method="PUT", headers=headers)
    with urllib.request.urlopen(request, timeout=300) as response:
        put_status = response.status
    asset_url = target["assetUrl"]
    say(f"10 clip PUT status={put_status} bytes={len(clip)} asset host={urllib.parse.urlparse(asset_url).hostname}")

    digest = bytearray(hashlib.sha256((workspace + "\n" + run_key + ":clip:" + hashlib.sha256(clip).hexdigest()).encode()).digest()[:16])
    digest[6] = (digest[6] & 0x0F) | 0x40
    digest[8] = (digest[8] & 0x3F) | 0x80
    attachment_id = str(uuid.UUID(bytes=bytes(digest)))
    attach = "mutation($input: AttachmentCreateInput!) { attachmentCreate(input: $input) { success attachment { id url } } }"
    attach_input = {"id": attachment_id, "issueId": issue_id_value, "url": asset_url, "title": "Scout clip · live check", "subtitle": "Recorded with Scout"}
    status, data, errors = gql(attach, {"input": attach_input}, mutation_team=team_id)
    created = (data or {}).get("attachmentCreate") or {}
    say(f"11 attachmentCreate with client id: status={status} success={created.get('success')} id_kept={(created.get('attachment') or {}).get('id') == attachment_id} errors={errors}")
    if errors:
        status, data, errors = gql("mutation($issue: String!, $url: String!, $title: String!) { attachmentLinkURL(issueId: $issue, url: $url, title: $title) { success attachment { id url } } }",
                                   {"issue": issue_id_value, "url": asset_url, "title": "Scout clip · live check"}, mutation_team=team_id)
        say(f"   attachmentLinkURL fallback: status={status} data={data} errors={errors}")

    status, data, errors = gql(attach, {"input": attach_input}, mutation_team=team_id)
    say(f"12 resend the same attachment id: status={status} data={data} errors={errors} (Scout treats 'already exists' or 'conflict' as done)")
    without_id = {k: v for k, v in attach_input.items() if k != "id"}
    status, data, errors = gql(attach, {"input": without_id}, mutation_team=team_id)
    say(f"13 same url without an id (marker mode): status={status} data={data} errors={errors}")

    _, data, errors = gql("query($id: String!) { issue(id: $id) { attachments { nodes { id url title subtitle sourceType } } } }", {"id": issue_id_value})
    nodes = (((data or {}).get("issue") or {}).get("attachments") or {}).get("nodes") or []
    say(f"14 read back attachments: count={len(nodes)} shapes={[{k: (v if k != 'url' else urllib.parse.urlparse(v).hostname) for k, v in n.items()} for n in nodes]} errors={errors}")
    say("   expect one attachment for the clip url; open the issue in the test team to confirm the clip plays (manual)")


def video_verify(key, team_id, out):
    say = logger(os.path.join(out, "video.log"))
    gql = client(key, team_id)
    for label in ["live-video-off", "live-video-redacted", "live-video-resend"]:
        path = os.path.join(out, label + ".json")
        steps = json.load(open(path)) if os.path.exists(path) else []
        prepared = [s for s in steps if s.get("step") == "video prepared"]
        task = ((steps[-1].get("tasks") or [{}])[0]) if steps else {}
        assets = task.get("uploadedAssets") or []
        videos = [a for a in assets if " video " in a]
        say(f"{label}: identifier={task.get('identifier') or '-'} state={task.get('state')} includeVideo={task.get('includeVideo')} redaction={task.get('redaction')} video assets={len(videos)} clipAttachment={task.get('clipAttachment')}")
        if prepared:
            p = prepared[-1]
            say(f"   prepared upload={p.get('uploadFile')} redacted={p.get('redacted')} upload={p.get('upload')} original={p.get('originalClip')}")
        issue_id = task.get("issueID")
        if not issue_id:
            continue
        _, data, errors = gql("query($id: String!) { issue(id: $id) { identifier title team { key } description attachments { nodes { id title subtitle url sourceType } } } }", {"id": issue_id})
        issue = (data or {}).get("issue") or {}
        lines = [l for l in (issue.get("description") or "").split("\n") if "clip.mp4" in l or "Video not included" in l]
        nodes = ((issue.get("attachments") or {}).get("nodes")) or []
        shapes = [{"title": n.get("title"), "subtitle": n.get("subtitle"), "host": urllib.parse.urlparse(n.get("url") or "").hostname, "sourceType": n.get("sourceType"), "id_matches_scout": n.get("id") == task.get("clipAttachment")} for n in nodes]
        clip_lines = [urllib.parse.urlparse(l.split("](")[1].split(")")[0]).hostname if "](" in l else l for l in lines]
        say(f"   read back {issue.get('identifier')} team={(issue.get('team') or {}).get('key')} title_prefixed={(issue.get('title') or '').startswith(TITLE_PREFIX)} clip line={clip_lines} attachments={shapes} errors={errors}")


def cleanup(key, team_id, out):
    say = logger(os.path.join(out, "cleanup.log"))
    gql = client(key, team_id)
    ids = []
    path = os.path.join(out, "created-ids.txt")
    if os.path.exists(path):
        ids += [line.strip() for line in open(path) if line.strip()]
    for name in sorted(os.listdir(out)):
        if name.startswith("live-") and name.endswith(".json"):
            for step in json.load(open(os.path.join(out, name))):
                for task in step.get("tasks") or []:
                    if task.get("issueID"):
                        ids.append(task["issueID"])
    seen = []
    for issue_id in ids:
        if issue_id not in seen:
            seen.append(issue_id)
    identifiers = []
    for issue_id in seen:
        _, data, errors = gql("query($id: String!) { issue(id: $id) { id identifier title archivedAt trashed team { id } } }", {"id": issue_id})
        issue = (data or {}).get("issue")
        if not issue:
            say(f"skip {issue_id}: not readable {errors}")
            continue
        if (issue.get("team") or {}).get("id") != team_id or not issue.get("title", "").startswith(TITLE_PREFIX):
            say(f"skip {issue['identifier']}: not a {TITLE_PREFIX.strip()} issue in the test team")
            continue
        if not issue.get("archivedAt"):
            _, data, errors = gql("mutation($id: String!) { issueArchive(id: $id) { success } }", {"id": issue_id}, mutation_team=team_id)
            ok = bool(((data or {}).get("issueArchive") or {}).get("success"))
            say(f"archive {issue['identifier']}: success={ok} errors={errors}")
        else:
            say(f"archive {issue['identifier']}: already archived")
        _, data, _ = gql("query($id: String!) { issue(id: $id) { identifier archivedAt } }", {"id": issue_id})
        after = (data or {}).get("issue") or {}
        identifiers.append(f"{issue['identifier']}\t{issue_id}\tarchivedAt={after.get('archivedAt')}")
    with open(os.path.join(out, "created-issues.txt"), "w") as handle:
        handle.write("\n".join(identifiers) + ("\n" if identifiers else ""))
    say(f"cleanup done: {len(identifiers)} issue(s) archived, listed in created-issues.txt")


def png_bytes():
    raw = b"".join(b"\x00" + bytes([240, 72, 42]) * 8 for _ in range(8))
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 8, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


if __name__ == "__main__":
    main()
