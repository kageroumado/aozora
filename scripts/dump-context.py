#!/usr/bin/env python3
"""Dump the initial context that Aozora would assemble for a session.

This builds the same context the daemon would use on startup:
1. Identity files (SOUL.md, IDENTITY.md, USER.md, HEARTBEAT.md)
2. LCM summaries (frontier nodes from the DAG)
3. Recent raw messages (last N, without tool results to save space)
4. Current core memory blocks

Output: ~/.aozora/debug-context.txt
"""
import sqlite3
import os
import sys
from pathlib import Path
from datetime import datetime

WORKSPACE = Path.home() / "Workspace"
DB_PATH = Path.home() / ".aozora" / "cims.db"
OUTPUT_PATH = Path.home() / ".aozora" / "debug-context.txt"
MAX_RECENT_MESSAGES = 50
MAX_SUMMARY_TOKENS = 80000  # ~80k tokens worth of summaries

def load_identity_files():
    """Load workspace identity files."""
    files = ["SOUL.md", "IDENTITY.md", "USER.md", "HEARTBEAT.md", "AGENTS.md", "TOOLS.md"]
    sections = []
    for f in files:
        path = WORKSPACE / f
        if path.exists():
            content = path.read_text()
            sections.append(f"## {f}\n\n{content}")
    return "\n\n---\n\n".join(sections)

def load_core_memory():
    """Load core memory blocks from the daemon's JSON store."""
    import json
    path = Path.home() / ".aozora" / "memory-blocks.json"
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}

def load_frontier_summaries(db):
    """Load LCM frontier summaries (the compacted context)."""
    cursor = db.execute("""
        SELECT n.nodeId, n.depth, n.kind, n.tokenCount, n.summaryText, 
               n.canonicalText, n.expandFooter, n.earliestAt, n.latestAt,
               c.sessionKey
        FROM lcm_frontier f
        JOIN lcm_nodes n ON f.nodeId = n.nodeId
        JOIN conversations c ON n.conversationId = c.id
        ORDER BY n.earliestAt ASC
    """)
    
    summaries = []
    total_chars = 0
    for row in cursor:
        node_id, depth, kind, tokens, summary, canonical, footer, earliest, latest, session_key = row
        conv_name = session_key
        text = summary or canonical or "(empty)"
        if total_chars + len(text) > MAX_SUMMARY_TOKENS * 4:  # rough char-to-token
            break
        summaries.append({
            "node_id": node_id,
            "depth": depth,
            "kind": kind,
            "tokens": tokens,
            "text": text,
            "footer": footer,
            "earliest": earliest,
            "latest": latest,
            "conversation": conv_name,
        })
        total_chars += len(text)
    return summaries

def load_recent_messages(db, session_key="agent:main:main"):
    """Load recent messages, excluding tool results to save context."""
    # Find the conversation for this session
    cursor = db.execute("""
        SELECT id FROM conversations 
        WHERE sessionKey LIKE ? OR sessionKey = ?
        ORDER BY lastMessageAt DESC LIMIT 1
    """, (f"%{session_key}%", session_key))
    row = cursor.fetchone()
    if not row:
        # Try the main conversation
        cursor = db.execute("SELECT id FROM conversations ORDER BY lastMessageAt DESC LIMIT 1")
        row = cursor.fetchone()
    if not row:
        return []
    
    conv_id = row[0]
    cursor = db.execute("""
        SELECT m.role, m.createdAt, m.content
        FROM messages m
        WHERE m.conversationId = ?
        AND m.role NOT IN ('tool_result', 'tool')
        ORDER BY m.createdAt DESC
        LIMIT ?
    """, (conv_id, MAX_RECENT_MESSAGES))
    
    messages = []
    for role, ts, content in cursor:
        if content and len(content) > 2000:
            content = content[:2000] + "\n... (truncated)"
        messages.append({"role": role, "timestamp": ts, "content": content or ""})
    
    messages.reverse()
    return messages

def main():
    if not DB_PATH.exists():
        print(f"❌ Database not found: {DB_PATH}")
        sys.exit(1)
    
    db = sqlite3.connect(str(DB_PATH))
    
    # Build context
    sections = []
    
    # 1. Header
    sections.append(f"# Aozora Debug Context Dump\n# Generated: {datetime.now().isoformat()}\n# Database: {DB_PATH}\n")
    
    # 2. Identity files
    identity = load_identity_files()
    sections.append(f"# ═══ IDENTITY FILES ═══\n# Total chars: {len(identity)}\n\n{identity}")
    
    # 3. Core memory blocks
    blocks = load_core_memory()
    if blocks:
        block_text = "\n\n".join(f"### {name}\n{content}" for name, content in blocks.items())
        sections.append(f"# ═══ CORE MEMORY ═══\n# Blocks: {len(blocks)}\n\n{block_text}")
    else:
        sections.append("# ═══ CORE MEMORY ═══\n# (no blocks found — will need to locate storage)")
    
    # 4. Frontier summaries
    summaries = load_frontier_summaries(db)
    total_summary_chars = sum(len(s["text"]) for s in summaries)
    summary_text = "\n\n".join(
        f"[{s['conversation']}] ({s['kind']}, depth={s['depth']}, ~{s['tokens']}tok, {s['latest']})\n"
        f"{s['text']}\n"
        f"{s['footer'] or ''}"
        for s in summaries
    )
    sections.append(f"# ═══ LCM FRONTIER SUMMARIES ═══\n# Nodes: {len(summaries)}, ~{total_summary_chars} chars\n\n{summary_text}")
    
    # 5. Recent messages
    messages = load_recent_messages(db)
    msg_text = "\n\n".join(
        f"[{m['role']}] ({m['timestamp']})\n{m['content']}"
        for m in messages
    )
    sections.append(f"# ═══ RECENT MESSAGES ═══\n# Count: {len(messages)} (tool results excluded)\n\n{msg_text}")
    
    # 6. Stats
    stats_cursor = db.execute("SELECT COUNT(*) FROM messages")
    total_messages = stats_cursor.fetchone()[0]
    stats_cursor = db.execute("SELECT COUNT(*) FROM lcm_nodes")
    total_nodes = stats_cursor.fetchone()[0]
    stats_cursor = db.execute("SELECT COUNT(*) FROM conversations")
    total_convs = stats_cursor.fetchone()[0]
    
    sections.append(f"""# ═══ DATABASE STATS ═══
# Conversations: {total_convs}
# Messages: {total_messages}
# DAG nodes: {total_nodes}
# Frontier nodes: {len(summaries)}
""")
    
    # Write output
    full_context = "\n\n" + "=" * 80 + "\n\n".join(sections)
    OUTPUT_PATH.write_text(full_context)
    
    print(f"✅ Context dumped to {OUTPUT_PATH}")
    print(f"   Size: {len(full_context):,} chars (~{len(full_context)//4:,} tokens)")
    print(f"   Identity: {len(identity):,} chars")
    print(f"   Summaries: {len(summaries)} nodes, {total_summary_chars:,} chars")
    print(f"   Recent messages: {len(messages)}")
    
    db.close()

if __name__ == "__main__":
    main()
