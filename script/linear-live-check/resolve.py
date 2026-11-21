import json
import sys
import urllib.error
import urllib.request

ENDPOINT = "https://api.linear.app/graphql"


def query(key, document):
    request = urllib.request.Request(ENDPOINT, data=json.dumps({"query": document}).encode(), headers={"Content-Type": "application/json", "Authorization": key})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        return {"errors": [{"message": f"HTTP {error.code}"}]}
    except (urllib.error.URLError, TimeoutError):
        return {"errors": [{"message": "unreachable"}]}


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: <key on stdin> resolve.py <secret name> <expected urlKey> <team key>")
    name, expected, team_key = sys.argv[1:]
    key = sys.stdin.readline().strip()
    if not key:
        print(f"{name} urlKey=none match=no {team_key}=none error=empty-key")
        return
    viewer = query(key, "query { viewer { organization { urlKey } } }")
    url_key = (((viewer.get("data") or {}).get("viewer") or {}).get("organization") or {}).get("urlKey")
    if not url_key:
        reason = str(((viewer.get("errors") or [{}])[0]).get("message", "no data"))[:80].replace(" ", "-")
        print(f"{name} urlKey=none match=no {team_key}=none error={reason}")
        return
    match = url_key == expected
    team_id = "none"
    if match:
        teams = query(key, "query { teams(first: 250) { nodes { id key } } }")
        nodes = (((teams.get("data") or {}).get("teams") or {}).get("nodes")) or []
        team_id = next((node["id"] for node in nodes if node.get("key") == team_key), "none")
    print(f"{name} urlKey={url_key} match={'yes' if match else 'no'} {team_key}={team_id}")


if __name__ == "__main__":
    main()
