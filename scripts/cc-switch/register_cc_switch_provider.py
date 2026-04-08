from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import time
import uuid
from pathlib import Path


def now_ms() -> int:
    return int(time.time() * 1000)


def backup_file(src: Path, backup_dir: Path, suffix: str, label: str | None = None) -> Path:
    backup_dir.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y%m%d_%H%M%S")
    part = f"{src.stem}_{label}" if label else src.stem
    dst = backup_dir / f"{part}_{suffix}_{ts}{src.suffix}"
    shutil.copy2(src, dst)
    return dst


def normalize_url(url: str) -> str:
    return url.rstrip("/")


def build_provider_config(
    gateway_url: str,
    gateway_token: str,
    chat_model: str,
    reasoning_model: str,
) -> dict:
    default_model = reasoning_model or chat_model
    return {
        "alwaysThinkingEnabled": False,
        "effortLevel": "low",
        "env": {
            "ANTHROPIC_AUTH_TOKEN": gateway_token,
            "ANTHROPIC_BASE_URL": gateway_url,
            "ANTHROPIC_MODEL": chat_model,
            "ANTHROPIC_REASONING_MODEL": reasoning_model,
            "ANTHROPIC_DEFAULT_SONNET_MODEL": default_model,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": default_model,
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": default_model,
        },
    }


def merge_provider_config(existing_config: dict | None, desired_config: dict) -> dict:
    merged = dict(existing_config or {})
    merged.setdefault("alwaysThinkingEnabled", desired_config["alwaysThinkingEnabled"])
    merged.setdefault("effortLevel", desired_config["effortLevel"])

    merged_env = dict(merged.get("env") or {})
    merged_env.update(desired_config["env"])
    merged["env"] = merged_env
    return merged


def upsert_provider(
    conn: sqlite3.Connection,
    name: str,
    provider_config: dict,
    website_url: str | None,
) -> tuple[str, bool]:
    cur = conn.cursor()
    cur.execute(
        "SELECT id, settings_config FROM providers WHERE app_type='claude' AND name=? LIMIT 1",
        (name,),
    )
    row = cur.fetchone()
    if row:
        provider_id = row[0]
        existing_config = None
        if row[1]:
            try:
                existing_config = json.loads(row[1])
            except json.JSONDecodeError:
                existing_config = None
        merged_config = merge_provider_config(existing_config, provider_config)
        config_json = json.dumps(merged_config, ensure_ascii=False)
        cur.execute(
            """
            UPDATE providers
               SET settings_config=?,
                   website_url=?,
                   category=COALESCE(category, 'gateway')
             WHERE id=?
            """,
            (config_json, website_url, provider_id),
        )
        created = False
    else:
        provider_id = str(uuid.uuid4())
        config_json = json.dumps(provider_config, ensure_ascii=False)
        cur.execute(
            """
            INSERT INTO providers (
                id, app_type, name, settings_config, website_url, category,
                created_at, sort_index, notes, icon, icon_color, meta,
                is_current, in_failover_queue, cost_multiplier, provider_type
            )
            VALUES (?, 'claude', ?, ?, ?, 'gateway',
                    ?, NULL, NULL, NULL, NULL, '{}',
                    0, 0, '1.0', NULL)
            """,
            (provider_id, name, config_json, website_url, now_ms()),
        )
        created = True
    return provider_id, created


def upsert_provider_endpoint(
    conn: sqlite3.Connection, provider_id: str, gateway_url: str
) -> None:
    cur = conn.cursor()
    cur.execute("DELETE FROM provider_endpoints WHERE provider_id=?", (provider_id,))
    cur.execute(
        """
        INSERT INTO provider_endpoints (provider_id, app_type, url, added_at)
        VALUES (?, 'claude', ?, ?)
        """,
        (provider_id, gateway_url, now_ms()),
    )


def parse_args() -> argparse.Namespace:
    home = Path.home()
    parser = argparse.ArgumentParser(
        description="Create or update a Claude provider in cc-switch for the CLIProxyAPI gateway."
    )
    parser.add_argument(
        "--db-path",
        default=str(home / ".cc-switch" / "cc-switch.db"),
        help="Path to cc-switch.db",
    )
    parser.add_argument(
        "--name",
        default="CLIProxyAPI Claude",
        help="Provider name shown in cc-switch",
    )
    parser.add_argument(
        "--gateway-url",
        default="http://127.0.0.1:3000",
        help="Anthropic-compatible gateway URL",
    )
    parser.add_argument(
        "--gateway-token",
        default=os.environ.get("CLI_PROXY_API_KEY", ""),
        help="Token used as ANTHROPIC_AUTH_TOKEN",
    )
    parser.add_argument(
        "--chat-model",
        default="gpt-5.4",
        help="Model used for ANTHROPIC_MODEL",
    )
    parser.add_argument(
        "--reasoning-model",
        default="gpt-5.4",
        help="Model used for ANTHROPIC_REASONING_MODEL",
    )
    parser.add_argument(
        "--website-url",
        default="http://127.0.0.1:3000",
        help="Optional website_url field",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    db_path = Path(args.db_path).expanduser().resolve()

    if not db_path.exists():
        raise SystemExit(f"cc-switch database not found: {db_path}")
    if not args.gateway_token:
        raise SystemExit(
            "gateway token is empty. Provide --gateway-token or set CLI_PROXY_API_KEY."
        )

    gateway_url = normalize_url(args.gateway_url)

    backup_dir = db_path.parent / "backups"
    db_backup = backup_file(db_path, backup_dir, "manual", label="db")

    provider_config = build_provider_config(
        gateway_url=gateway_url,
        gateway_token=args.gateway_token,
        chat_model=args.chat_model,
        reasoning_model=args.reasoning_model,
    )

    conn = sqlite3.connect(str(db_path))
    try:
        provider_id, created = upsert_provider(
            conn=conn,
            name=args.name,
            provider_config=provider_config,
            website_url=args.website_url,
        )
        upsert_provider_endpoint(conn=conn, provider_id=provider_id, gateway_url=gateway_url)
        conn.commit()
    finally:
        conn.close()

    print("Done.")
    print(f"Provider ID: {provider_id}")
    print(f"Created   : {created}")
    print(f"DB Backup : {db_backup}")
    print("Updated cc-switch provider data only.")
    print("Next step: open cc-switch and manually select this Claude provider.")
    print("Tip: restart cc-switch UI if the provider does not appear immediately.")


if __name__ == "__main__":
    main()
