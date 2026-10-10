# Source before EACH corpus batch (#196 track 196.7): API credit first, then
# the Claude subscription. Sets LLM_GATEWAY for the next batch only, so a
# batch never switches route halfway. Fail-safe = subscription.
#
#   source scripts/llm_route.sh   # needs root .env loaded; PY = python with quiz_shared
#
# API route keeps the gateway from .env (default direct): Claude ids go
# straight to Anthropic and draw the credit; checks stay on their providers.
_llm_route=$("${PY:-python}" -m quiz_shared.llm.credit_gate) || _llm_route=session
if [ "$_llm_route" = api ]; then
  export LLM_GATEWAY="${LLM_GATEWAY_API:-direct}"
else
  export LLM_GATEWAY=session
fi
echo "llm_route: LLM_GATEWAY=$LLM_GATEWAY"
