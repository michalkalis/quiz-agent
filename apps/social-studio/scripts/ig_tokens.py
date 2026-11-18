"""Instagram tokens: refresh in the root .env and copy them to GitHub secrets (210.5).

    uv run --no-sync python apps/social-studio/scripts/ig_tokens.py

Dashboard tokens are long-lived (60 days) and can be refreshed once they are
24 h old; an expired one cannot. Run it with every weekly batch: each token in
`.env` (IG_TOKEN_IG_EN, IG_TOKEN_IG_SKCZ) is refreshed, written back and set as
the GitHub secret of the same name, which the publish workflow reads. Token
values are never printed.
"""

import os
import subprocess

from dotenv import find_dotenv, load_dotenv, set_key
from publish_due import ACCOUNTS, call


def main() -> None:
    env = find_dotenv(usecwd=True)  # root .env of the checkout you run it from
    load_dotenv(env)
    for account in ACCOUNTS:
        name = f"IG_TOKEN_{account.upper()}"
        token = os.environ.get(name)
        if not token:
            print(f"{name}: not in .env, skipped")
            continue
        try:
            new = call(
                "GET", "refresh_access_token", token, grant_type="ig_refresh_token"
            )
            token = new["access_token"]
            set_key(env, name, token, quote_mode="never")
            print(f"{name}: refreshed, valid {new['expires_in'] // 86400} days")
        except RuntimeError as e:
            print(
                f"{name}: not refreshed ({str(e)[:200]})"
            )  # younger than 24 h: keep as is
        subprocess.run(["gh", "secret", "set", name], input=token.encode(), check=True)
        print(f"{name}: GitHub secret updated")


if __name__ == "__main__":
    main()
