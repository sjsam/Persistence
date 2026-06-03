"""CLI for exercising the memory engine without an MCP client.

    persistence save  <project> <content...> [--tags a,b]
    persistence recall <query...> [--project P] [--top-k N]
    persistence projects
    persistence list   <project>
    persistence doctor
"""

from __future__ import annotations

import argparse
import json
import sys

from .config import Config
from .embeddings import Embedder
from .store import MemoryStore


def _print(obj) -> None:
    print(json.dumps(obj, indent=2, ensure_ascii=False))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="persistence", description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_save = sub.add_parser("save", help="append a memory delta")
    p_save.add_argument("project")
    p_save.add_argument("content", nargs="+")
    p_save.add_argument("--tags", default="", help="comma-separated tags")

    p_recall = sub.add_parser("recall", help="semantic recall")
    p_recall.add_argument("query", nargs="+")
    p_recall.add_argument("--project", default=None)
    p_recall.add_argument("--top-k", type=int, default=5)

    sub.add_parser("projects", help="list known projects")

    p_list = sub.add_parser("list", help="list a project's deltas")
    p_list.add_argument("project")

    p_backup = sub.add_parser("backup", help="hot-copy the DB to a file")
    p_backup.add_argument("dest", help="destination path for the backup")

    sub.add_parser("doctor", help="check Ollama + DB health")

    args = parser.parse_args(argv)
    config = Config.from_env()

    if args.cmd == "doctor":
        return _doctor(config)

    store = MemoryStore(config)

    if args.cmd == "save":
        tags = [t.strip() for t in args.tags.split(",") if t.strip()]
        mem = store.save(
            project=args.project,
            content=" ".join(args.content),
            tags=tags,
            source_tool="cli",
        )
        _print(mem.to_dict())
    elif args.cmd == "recall":
        results = store.recall(
            query=" ".join(args.query), project=args.project, top_k=args.top_k
        )
        _print([m.to_dict() for m in results])
    elif args.cmd == "projects":
        _print(store.list_projects())
    elif args.cmd == "list":
        _print([m.to_dict() for m in store.list_memories(args.project)])
    elif args.cmd == "backup":
        dest = store.backup(args.dest)
        _print({"backed_up_to": str(dest)})

    store.close()
    return 0


def _doctor(config: Config) -> int:
    print(f"DB path:    {config.db_path}")
    print(f"Ollama URL: {config.ollama_url}")
    print(f"Embed:      {config.embed_model} ({config.embed_dim}d)")
    embedder = Embedder(config)
    if embedder.available():
        print("Ollama:     OK — semantic recall enabled")
        return 0
    print("Ollama:     UNAVAILABLE — recall will fall back to keyword search")
    print("            Fix: `ollama serve` and `ollama pull " + config.embed_model + "`")
    return 1


if __name__ == "__main__":
    sys.exit(main())
