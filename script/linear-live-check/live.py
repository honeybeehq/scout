import hashlib
import re
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
    elif command == "parent-verify":
        parent_verify(key, team_id, out)
    elif command == "dupe-seed":
        dupe_seed(key, team_id, out, sys.argv[4])
    elif command == "dupe-wait":
        dupe_wait(key, team_id, out, sys.argv[4])
    elif command == "dupe-verify":
        dupe_verify(key, team_id, out)
    elif command == "cleanup":
        cleanup(key, team_id, out)
    else:
        sys.exit("usage: <key on stdin> live.py check|video-verify|parent-verify|dupe-seed|dupe-wait|dupe-verify|cleanup <team id> <out dir> [clip.mp4 | seed title]")


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

    check_parent(gql, say, team_id, workspace, run_key, issue_id, created_file)




def check_parent(gql, say, team_id, workspace, run_key, issue_id, created_file):
    create = "mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier url } } }"
    read = "query($id: String!) { issue(id: $id) { id identifier trashed archivedAt parent { id identifier url } } }"
    parent_key = run_key + ":parent"
    parent_id = issue_id(workspace, parent_key)
    children = [(run_key + f":task-{n}", TITLE_PREFIX + f"Scout live check sub-issue {n}") for n in (1, 2)]
    say("15 parent + sub-issues: parent first with a derived id, then children with parentId and subIssueSortOrder in task order")
    _, data, errors = gql('query { __type(name: "IssueCreateInput") { inputFields { name } } }')
    fields = [f.get("name") for f in (((data or {}).get("__type") or {}).get("inputFields") or [])]
    say(f"   IssueCreateInput has subIssueSortOrder={'subIssueSortOrder' in fields} sortOrder={'sortOrder' in fields} errors={errors}")
    parent_input = {"id": parent_id, "teamId": team_id, "title": TITLE_PREFIX + "Scout live check parent", "description": f"Live check of Scout's T5 slice.\n\n### Sub-issues\n1. sub-issue 1\n2. sub-issue 2\n\n---\nFiled from Scout · `{parent_key}`", "labelIds": [], "priority": 0}
    status, data, errors = gql(create, {"input": parent_input}, mutation_team=team_id)
    parent = ((data or {}).get('issueCreate') or {}).get('issue') or {}
    say(f"   parent issueCreate: status={status} issue={parent} errors={errors}")
    if parent.get("id"):
        created_file.write(parent["id"] + "\n")
        created_file.flush()
    if parent.get("id") != parent_id:
        say("   parent was not created with its derived id; stopping the parent checks")
        return
    identifiers = []
    for position, (key, title) in enumerate(children):
        child_input = {"id": issue_id(workspace, key), "teamId": team_id, "parentId": parent_id, "subIssueSortOrder": position, "title": title, "description": f"---\nFiled from Scout · `{key}`", "labelIds": [], "priority": 0}
        status, data, errors = gql(create, {"input": child_input}, mutation_team=team_id)
        issue = ((data or {}).get("issueCreate") or {}).get("issue") or {}
        identifiers.append(issue.get("identifier"))
        if issue.get("id"):
            created_file.write(issue["id"] + "\n")
            created_file.flush()
        say(f"   child issueCreate {key}: status={status} issue={issue} errors={errors}")
    update = "mutation($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }"
    tidy = parent_input["description"].replace("1. sub-issue 1", f"1. {identifiers[0]} · sub-issue 1").replace("2. sub-issue 2", f"2. {identifiers[1]} · sub-issue 2")
    status, data, errors = gql(update, {"id": parent_id, "input": {"description": tidy}}, mutation_team=team_id)
    say(f"16 parent issueUpdate (tidy): status={status} data={data} errors={errors}")
    for key, _ in children:
        _, data, errors = gql(read, {"id": issue_id(workspace, key)})
        issue = (data or {}).get("issue") or {}
        say(f"17 read back {key}: identifier={issue.get('identifier')} parent={(issue.get('parent') or {}).get('identifier')} parent_id_matches={(issue.get('parent') or {}).get('id') == parent_id} errors={errors}")
    status, data, errors = gql(create, {"input": parent_input}, mutation_team=team_id)
    say(f"18 resend the parent id: status={status} data={data} errors={errors} (expect a conflict; Scout reads issue(id:) first and adopts)")
    duplicate = (((data or {}).get("issueCreate") or {}).get("issue") or {}).get("id")
    if duplicate and duplicate != parent_id:
        created_file.write(duplicate + "\n")
        created_file.flush()
        say(f"   DUPLICATE parent created by the resend: {duplicate}")
    _, data, errors = gql("query($id: String!) { issue(id: $id) { children { nodes { identifier number subIssueSortOrder } } description } }", {"id": parent_id})
    issue = (data or {}).get("issue") or {}
    raw = (issue.get("children") or {}).get("nodes") or []
    say(f"   children as returned={[(n.get('identifier'), n.get('subIssueSortOrder')) for n in raw]}")
    nodes = [n.get("identifier") for n in sorted(raw, key=lambda n: (n.get("subIssueSortOrder") is None, n.get("subIssueSortOrder") or 0))]
    say(f"19 parent children={nodes} (expect exactly {identifiers}) tidied={all(i and i in (issue.get('description') or '') for i in identifiers)} errors={errors}")


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
    still_linked = False
    for label in ["live-video-off", "live-video-redacted", "live-video-resend", "live-video-unlinked"]:
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
        clip_lines = []
        for l in lines:
            found = re.search(r"https?://[^\s)>\]]+", l)
            clip_lines.append(("link to " + (urllib.parse.urlparse(found.group(0)).hostname or "?")) if found else l.strip()[:80])
        if lines and not clip_lines:
            clip_lines = [l.strip()[:80] for l in lines]
        if label in ("live-video-off", "live-video-unlinked") and (any("clip.mp4" in l for l in lines) or nodes):
            still_linked = True
            say(f"   STILL LINKED: {label} must have no clip link and no clip card")
        say(f"   read back {issue.get('identifier')} team={(issue.get('team') or {}).get('key')} title_prefixed={(issue.get('title') or '').startswith(TITLE_PREFIX)} clip line={clip_lines} attachments={shapes} errors={errors}")
    if still_linked:
        sys.exit(6)


def parent_verify(key, team_id, out):
    say = logger(os.path.join(out, "parent.log"))
    gql = client(key, team_id)
    runs = ["live-6-parent", "live-7-parent-resend", "live-8-parent-no-review-json"]
    last = {}
    for label in runs:
        path = os.path.join(out, label + ".json")
        steps = json.load(open(path)) if os.path.exists(path) else []
        last[label] = steps[-1] if steps else {}
    problems = []
    parents = {label: step.get("parentIssueID") for label, step in last.items()}
    children = {label: [t.get("issueID") for t in step.get("tasks") or []] for label, step in last.items()}
    for label, step in last.items():
        say(f"{label}: parent={step.get('parent')} tasks={[(t.get('identifier'), t.get('subIssueOf')) for t in step.get('tasks') or []]}")
    first = runs[0]
    if not parents[first]:
        problems.append("live-6: no parent was filed")
    if len(set(parents.values())) != 1:
        problems.append(f"the parent changed between runs: {parents}")
    if any(not ids or not all(ids) for ids in children.values()) or len({tuple(ids) for ids in children.values()}) != 1:
        problems.append(f"the sub-issues changed between runs: {children}")
    parent_identifier = (last[first].get("parent") or "").split(" ")[0]
    for task in last[first].get("tasks") or []:
        if task.get("subIssueOf") != parent_identifier:
            problems.append(f"{task.get('identifier')} is not a sub-issue of {parent_identifier}")
    if parents[first]:
        _, data, errors = gql("query($id: String!) { issue(id: $id) { identifier title team { id } children { nodes { id identifier title number subIssueSortOrder } } description } }", {"id": parents[first]})
        issue = (data or {}).get("issue") or {}
        nodes = sorted(((issue.get("children") or {}).get("nodes") or []), key=lambda n: (n.get("subIssueSortOrder") is None, n.get("subIssueSortOrder") or 0))
        say(f"read back parent {issue.get('identifier')} title={issue.get('title')!r} children by subIssueSortOrder={[(n.get('identifier'), n.get('subIssueSortOrder')) for n in nodes]} errors={errors}")
        if (issue.get("team") or {}).get("id") != team_id or not (issue.get("title") or "").startswith(TITLE_PREFIX):
            problems.append("the parent is not a prefixed issue in the test team")
        if [n.get("id") for n in nodes] != children[first]:
            problems.append(f"Linear lists children {[n.get('identifier') for n in nodes]}, Scout filed {[t.get('identifier') for t in last[first].get('tasks') or []]} in task order")
        if any(not (n.get("title") or "").startswith(TITLE_PREFIX) for n in nodes):
            problems.append("a sub-issue title lacks the test prefix")
        listed = [n.get("identifier") for n in nodes if n.get("identifier") and n.get("identifier") in (issue.get("description") or "")]
        say(f"parent description lists {listed}")
        if len(listed) != len(nodes):
            problems.append("the parent description does not list every sub-issue after the tidy")
    say("\n".join(problems) if problems else "Scout parent flow: one parent, sub-issues in task order, resend and resend without review.json created nothing")
    sys.exit(6 if problems else 0)


DUPLICATES = "query($term: String!, $team: ID!) { searchIssues(term: $term, first: 6, filter: { team: { id: { eq: $team } }, state: { type: { nin: [\"completed\", \"canceled\"] } } }) { nodes { id identifier title url trashed archivedAt state { name } } } }"


def dupe_seed(key, team_id, out, title):
    say = logger(os.path.join(out, "dupe.log"))
    gql = client(key, team_id)
    if not title.startswith(TITLE_PREFIX):
        sys.exit("the seed title must start with the test prefix")
    say(f"20 introspection (read-only): which search the API exposes, and the shapes Scout's duplicate check and comment use")
    _, data, errors = gql('query { q: __type(name: "Query") { fields { name isDeprecated args { name } } } c: __type(name: "CommentCreateInput") { inputFields { name } } f: __type(name: "IssueFilter") { inputFields { name } } w: __type(name: "WorkflowStateFilter") { inputFields { name } } }')
    data = data or {}
    searches = [(f["name"], "deprecated" if f.get("isDeprecated") else "current", [a["name"] for a in f.get("args") or []]) for f in ((data.get("q") or {}).get("fields") or []) if "search" in f["name"].lower() and "issue" in f["name"].lower()]
    say(f"   Query search fields: {searches}")
    say(f"   CommentCreateInput fields: {sorted(f['name'] for f in ((data.get('c') or {}).get('inputFields') or []))}")
    say(f"   IssueFilter has team={any(f['name'] == 'team' for f in ((data.get('f') or {}).get('inputFields') or []))} state={any(f['name'] == 'state' for f in ((data.get('f') or {}).get('inputFields') or []))}; WorkflowStateFilter has type={any(f['name'] == 'type' for f in ((data.get('w') or {}).get('inputFields') or []))} errors={errors}")
    create = "mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier url } } }"
    description = "Seeded by Scout's live check (T6): an open issue the duplicate check should find. Scout adds the task to it as one comment."
    status, data, errors = gql(create, {"input": {"teamId": team_id, "title": title, "description": description, "labelIds": [], "priority": 0}}, mutation_team=team_id)
    issue = ((data or {}).get("issueCreate") or {}).get("issue") or {}
    say(f"21 seeded {issue.get('identifier')} title={title!r} status={status} errors={errors}")
    if not issue.get("id"):
        sys.exit(7)
    with open(os.path.join(out, "created-ids.txt"), "a") as handle:
        handle.write(issue["id"] + "\n")
    with open(os.path.join(out, "dupe-seeded.txt"), "w") as handle:
        handle.write(issue["id"] + "\t" + issue["identifier"] + "\t" + issue["url"] + "\t" + str(time.time()) + "\n")
    print(issue["id"])


def dupe_wait(key, team_id, out, term):
    say = logger(os.path.join(out, "dupe.log"))
    gql = client(key, team_id)
    seeded_id, identifier, url, created = open(os.path.join(out, "dupe-seeded.txt")).read().split("\t")
    started = time.time()
    found, errors = [], []
    while True:
        _, data, errors = gql(DUPLICATES, {"term": term, "team": team_id})
        nodes = (((data or {}).get("searchIssues") or {}).get("nodes")) or []
        found = [n.get("identifier") for n in nodes]
        if seeded_id in [n.get("id") for n in nodes] or time.time() - started > 300:
            break
        time.sleep(10)
    hit = identifier in found
    say(f"22 Scout's duplicate query (term={term!r}) finds {identifier}: {hit}, {int(time.time() - float(created))} s after seeding, results={found} errors={errors}")
    with open(os.path.join(out, "dupe-search.txt"), "w") as handle:
        handle.write(("found" if hit else "missed") + "\n")
    print(f"{seeded_id} {identifier} {url}")


def dupe_verify(key, team_id, out):
    say = logger(os.path.join(out, "dupe.log"))
    gql = client(key, team_id)
    seeded_id, seeded_identifier = open(os.path.join(out, "dupe-seeded.txt")).read().split("\t")[:2]
    problems = []
    search = open(os.path.join(out, "dupe-search.txt")).read().strip() if os.path.exists(os.path.join(out, "dupe-search.txt")) else "not run"
    if search != "found":
        problems.append(f"Linear's search did not return {seeded_identifier} within the poll ({search})")
    runs = ["live-10-dupe-add", "live-11-dupe-resend", "live-12-dupe-no-review-json"]
    comments = set()
    for label in runs:
        path = os.path.join(out, label + ".json")
        steps = json.load(open(path)) if os.path.exists(path) else []
        checks = [s for s in steps if s.get("step") == "duplicate check"]
        if checks:
            say(f"{label}: duplicate check term={checks[-1].get('term')!r} found={[c.get('identifier') for c in checks[-1].get('candidates') or []]}")
        task = ((steps[-1].get("tasks") or [{}])[0]) if steps else {}
        say(f"{label}: state={task.get('state')} sentText={task.get('sentText')!r} addedTo={task.get('addedTo')} comment={task.get('commentID')} clipAttachment={task.get('clipAttachment')}")
        if task.get("addedToIssueID") != seeded_id:
            problems.append(f"{label}: not added to the seeded issue {seeded_identifier}")
        comments.add(task.get("commentID"))
    if len(comments) != 1 or not next(iter(comments)):
        problems.append(f"the comment changed between runs: {comments}")
    _, data, errors = gql("query($id: String!) { issue(id: $id) { identifier title team { id } comments(first: 50) { nodes { id url body } } attachments(first: 50) { nodes { id title subtitle url } } } }", {"id": seeded_id})
    issue = (data or {}).get("issue") or {}
    nodes = ((issue.get("comments") or {}).get("nodes")) or []
    scout = [n for n in nodes if "Added from Scout" in (n.get("body") or "")]
    attachments = ((issue.get("attachments") or {}).get("nodes")) or []
    say(f"read back {issue.get('identifier')}: team is the test team={(issue.get('team') or {}).get('id') == team_id} comments={len(nodes)} from Scout={len(scout)} attachments={[(a.get('title'), a.get('subtitle'), urllib.parse.urlparse(a.get('url') or '').hostname) for a in attachments]} errors={errors}")
    for n in scout:
        body = n.get("body") or ""
        say(f"   comment {n.get('id')} id_matches_scout={n.get('id') in comments} url_host={urllib.parse.urlparse(n.get('url') or '').hostname} footer={body.splitlines()[-1] if body else ''!r} clip_link={'clip.mp4' in body} has_context_heading={'### Context' in body} chars={len(body)}")
    if len(scout) != 1:
        problems.append(f"expected exactly one Scout comment on {seeded_identifier}, found {len(scout)}")
    clips = [a for a in attachments if a.get("subtitle") == "Recorded with Scout"]
    if len(clips) != 1:
        problems.append(f"expected one clip card on {seeded_identifier}, found {len(clips)}")
    say("\n".join(problems) if problems else f"Scout dedupe flow: search found {seeded_identifier}; Add to it made one comment and one clip card; the resend and the resend without review.json made nothing new")
    sys.exit(6 if problems else 0)


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
                if step.get("parentIssueID"):
                    ids.append(step["parentIssueID"])
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
