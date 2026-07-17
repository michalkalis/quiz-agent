FROM redis:7.4-alpine

# Password comes from the Fly secret REDIS_PASSWORD; sh -c is required for
# env expansion (exec-form CMD does not expand variables).
CMD ["sh", "-c", "exec redis-server \
  --requirepass \"$REDIS_PASSWORD\" \
  --bind 0.0.0.0 :: \
  --protected-mode no \
  --appendonly yes \
  --dir /data \
  --maxmemory 192mb \
  --maxmemory-policy noeviction"]
