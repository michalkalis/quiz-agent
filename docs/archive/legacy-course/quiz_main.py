#!/usr/bin/env python3
"""
Quiz Agent - Terminal entry point.

Usage: python quiz_main.py

Commands: start, quit, harder, easier, skip
"""

import asyncio
import os
from dotenv import load_dotenv
from langchain_mcp_adapters.client import MultiServerMCPClient
from langchain_core.messages import HumanMessage
from graph import create_quiz_graph, get_initial_state, get_tavily_mcp_url


async def main():
    load_dotenv()

    if not os.getenv("OPENAI_API_KEY"):
        print("Error: OPENAI_API_KEY not set")
        return

    # Initialize MCP tools
    mcp_tools = None
    if os.getenv("TAVILY_API_KEY"):
        print("Connecting to Tavily...")
        client = MultiServerMCPClient({
            "tavily": {"url": get_tavily_mcp_url(), "transport": "streamable_http"}
        })
        mcp_tools = await client.get_tools()
        print(f"Loaded {len(mcp_tools)} tools")
    else:
        print("Warning: TAVILY_API_KEY not set, source lookup disabled")

    # Create graph and initial state
    graph = await create_quiz_graph(mcp_tools)
    state = get_initial_state()

    # Welcome message
    print(f"\n{state['pending_output']}")
    print("Commands: start, quit, harder, easier, skip\n")
    state["pending_output"] = None

    # Main loop
    while True:
        try:
            user_input = input("> ").strip()
            if not user_input:
                continue

            state["messages"].append(HumanMessage(content=user_input))
            state["pending_output"] = None

            result = await graph.ainvoke(state)
            state.update(result)

            if state.get("pending_output"):
                print(f"\n{state['pending_output']}\n")
                state["pending_output"] = None

            if state.get("phase") == "finished":
                break

        except (KeyboardInterrupt, EOFError):
            print("\nGoodbye!")
            break


if __name__ == "__main__":
    asyncio.run(main())
