"""Smoke test: connect to the running Persistence MCP server and call each tool."""

import asyncio
import json
import sys

from fastmcp import Client


async def main(url: str) -> int:
    async with Client(url) as client:
        tools = await client.list_tools()
        print("TOOLS:", [t.name for t in tools])

        await client.call_tool(
            "save_memory",
            {
                "project": "persistence",
                "content": "Cross-tool handoff test: server reachable over MCP HTTP on 8077.",
                "tags": ["smoke", "mcp"],
            },
        )
        print("save_memory: OK")

        res = await client.call_tool(
            "recall_memory",
            {"query": "is the mcp server reachable", "project": "persistence", "top_k": 1},
        )
        print("recall_memory:", json.dumps(res.data, indent=2))

        projects = await client.call_tool("list_projects", {})
        print("list_projects:", json.dumps(projects.data, indent=2))
    return 0


if __name__ == "__main__":
    url = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8077/mcp"
    sys.exit(asyncio.run(main(url)))
