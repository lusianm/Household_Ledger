"""Read the live ledger snapshot and submit atomic, version-checked edits.

Only request.json is edited by this client; the running app owns the ledger.
"""
import argparse
import json
import os
from pathlib import Path
import sys
import time
import uuid


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def connection_folder(path):
    folder = Path(path).expanduser().resolve()
    if folder.name != "codex":
        if folder.name != "ChagokLedger":
            folder = folder / "ChagokLedger"
        folder = folder / "codex"
    marker = read_json(folder / "owner.json")
    owner = read_json(folder.parent / "owner.json")
    if (marker.get("format") != "chagok-file-connection"
            or marker.get("version") != 1
            or owner.get("format") != "chagok-folder"
            or marker.get("owner") != owner.get("id")):
        raise ValueError("가계부 연결 폴더 식별자가 일치하지 않습니다.")
    return folder


def snapshot(folder):
    data = read_json(folder / "snapshot.json")
    if data.get("format") != "chagok-file-snapshot" or data.get("version") != 1:
        raise ValueError("지원하지 않는 snapshot.json 형식입니다.")
    if not data.get("enabled"):
        raise ValueError("앱 설정에서 Codex 파일 연결을 켜 주세요.")
    return data


def result_for(folder, request):
    try:
        result = read_json(folder / "result.json")
    except (FileNotFoundError, json.JSONDecodeError):
        return None
    if (result.get("format") == "chagok-file-result"
            and result.get("version") == 1
            and all(result.get(k) == request.get(k) for k in ("id", "ledger", "connection"))):
        return result
    return None


def publish(folder, data, plan):
    if (plan.get("ledger") != data["ledger"]
            or plan.get("connection") != data["connection"]):
        raise ValueError("계획의 가계부/연결이 다릅니다. 최신 snapshot으로 다시 검토하세요.")
    ops = plan.get("operations")
    if not isinstance(ops, list) or not 1 <= len(ops) <= 500:
        raise ValueError("operations에는 1~500건이 필요합니다.")
    current = {e["data"]["id"]: e for e in data["entries"]}
    ids = set()
    for op in ops:
        entry = current.get(op.get("id"))
        if (entry is None or not entry["editable"] or op["id"] in ids
                or entry["base"] != op.get("base")):
            raise ValueError(f"수정할 수 없거나 변경된 거래: {op.get('id')}")
        if not isinstance(op.get("set"), dict) or not op["set"]:
            raise ValueError("각 작업에는 비어 있지 않은 set 객체가 필요합니다.")
        ids.add(op["id"])
    request_path = folder / "request.json"
    if request_path.exists():
        previous = read_json(request_path)
        same_connection = all(previous.get(k) == data.get(k) for k in ("ledger", "connection"))
        if same_connection and result_for(folder, previous) is None:
            raise ValueError("이전 요청이 아직 처리되지 않았습니다. status로 확인하세요.")
    request = {
        "format": "chagok-file-request", "version": 1,
        "id": str(uuid.uuid4()),
        "ledger": data["ledger"], "connection": data["connection"],
        "operations": ops,
    }
    raw = json.dumps(request, ensure_ascii=False, indent=2).encode("utf-8")
    if len(raw) > 1024 * 1024:
        raise ValueError("요청 파일은 1MiB 이하여야 합니다.")
    temp = folder / f".request-{request['id']}.tmp"
    try:
        with temp.open("xb") as handle:
            handle.write(raw)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, request_path)
    finally:
        temp.unlink(missing_ok=True)
    return request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--folder", required=True, help="선택 폴더, ChagokLedger 또는 codex 경로")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    query = commands.add_parser("query")
    query.add_argument("--account")
    query.add_argument("--search", default="")
    apply = commands.add_parser("apply")
    apply.add_argument("--plan", required=True)
    apply.add_argument("--wait", type=float, default=30)
    args = parser.parse_args()
    folder = connection_folder(args.folder)
    data = snapshot(folder)
    if args.command == "status":
        result = {
            "ledger": data["ledger"], "connection": data["connection"],
            "snapshot_updated_at": data.get("updated_at"),
            "entries": len(data["entries"]), "unsent": data.get("unsent"),
        }
        request = folder / "request.json"
        if request.exists():
            pending = read_json(request)
            result["request"] = pending["id"]
            result["result"] = result_for(folder, pending) or {"status": "pending"}
        print(json.dumps(result, ensure_ascii=False, indent=2))
    elif args.command == "query":
        accounts = {a["id"]: a["name"] for a in data["accounts"]}
        entries = []
        for item in data["entries"]:
            e = item["data"]
            names = [accounts.get(p["account"], p["account"]) for p in e["postings"]]
            if args.account and args.account not in names:
                continue
            if args.search not in e["memo"]:
                continue
            entries.append({**item, "account_names": names})
        print(json.dumps({
            "ledger": data["ledger"], "connection": data["connection"],
            "updated_at": data.get("updated_at"), "entries": entries,
            "accounts": data["accounts"], "categories": data["categories"],
        }, ensure_ascii=False, indent=2))
    else:
        if not 0 <= args.wait <= 60:
            raise ValueError("--wait는 0~60초여야 합니다.")
        lock = folder / "client.lock"
        # Cooperative CLI lock: do not replace another client's pending request.
        try:
            descriptor = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError as exc:
            raise ValueError("다른 클라이언트가 실행 중입니다. client.lock을 확인하세요.") from exc
        try:
            os.close(descriptor)
            request = publish(folder, snapshot(folder), read_json(Path(args.plan)))
            deadline = time.monotonic() + args.wait
            while True:
                result = result_for(folder, request)
                if result is not None:
                    print(json.dumps(result, ensure_ascii=False, indent=2))
                    return 0 if result["status"] == "applied" else 1
                if time.monotonic() >= deadline:
                    print(json.dumps({
                        "id": request["id"], "status": "pending",
                        "message": "아직 저장 완료 응답이 없습니다. 앱을 열고 status로 확인하세요. 요청은 대기 중이며 재전송하지 마세요.",
                    }, ensure_ascii=False, indent=2))
                    return 2
                time.sleep(0.25)
        finally:
            lock.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"연결 오류: {error}", file=sys.stderr)
        raise SystemExit(1)
