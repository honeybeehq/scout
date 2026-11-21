import json
import sys
import urllib.error
import urllib.request

ENDPOINT = "https://api.linear.app/graphql"
TITLE_PREFIX = "[scout-test] "


def read_key(text):
    for line in text.splitlines():
        if "key=" in line:
            value = line.split("key=", 1)[1].strip()
            for stop in (" ", "\t", "|", "│"):
                value = value.split(stop, 1)[0]
            return value.strip()
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return lines[0] if lines else ""


def gql(key, document, variables):
    body = json.dumps({"query": document, "variables": variables}).encode()
    request = urllib.request.Request(ENDPOINT, data=body, headers={"Content-Type": "application/json", "Authorization": key})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            reply = json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        return None, [f"HTTP {error.code}"]
    return reply.get("data"), [str(e.get("message", ""))[:160] for e in reply.get("errors") or []]


def clean(value, limit=120):
    text = "" if value is None else str(value)
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    archive = "--archive-if-scout-test" in sys.argv
    if len(args) != 3:
        sys.exit("usage: <key on stdin> inspect_issue.py <team id> <team key> <number> [--archive-if-scout-test]")
    team_id, team_key, number = args
    key = read_key(sys.stdin.read())
    identifier = f"{team_key}-{int(number)}"
    data, errors = gql(key, "query($id: String!) { issue(id: $id) { id identifier title createdAt archivedAt trashed team { id key } creator { name } } }", {"id": identifier})
    issue = (data or {}).get("issue")
    if not issue:
        print(f"{identifier}: not found ({'; '.join(errors) or 'no data'})")
        return
    team = issue.get("team") or {}
    fields = {
        "identifier": issue.get("identifier"),
        "title": issue.get("title"),
        "createdAt": issue.get("createdAt"),
        "archivedAt": issue.get("archivedAt"),
        "trashed": issue.get("trashed"),
        "team": team.get("key"),
        "creator": (issue.get("creator") or {}).get("name"),
    }
    print(" ".join(f"{name}={clean(value)!r}" for name, value in fields.items()))
    ours = team.get("id") == team_id and str(issue.get("title", "")).startswith(TITLE_PREFIX)
    print(f"scout-test issue in the test team: {'yes' if ours else 'no'}")
    if archive and ours and not issue.get("archivedAt"):
        data, errors = gql(key, "mutation($id: String!) { issueArchive(id: $id) { success } }", {"id": issue["id"]})
        print(f"archived: {bool(((data or {}).get('issueArchive') or {}).get('success'))} {'; '.join(errors)}")


if __name__ == "__main__":
    main()
