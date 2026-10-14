"""Entry point of the weekly fresh-entertainment run (#202 — weekly fresh entertainment job).

    python -m app.corpus.run_fresh_topup --languages en,sk,cs [--dry-run] ...

Applies the env pins first, then imports the job (see ``fresh_pins``).
"""

import sys

from app.corpus import fresh_pins

fresh_pins.apply()

from app.corpus.fresh_topup import main  # pins must come first

sys.exit(main())
