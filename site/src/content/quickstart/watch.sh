# In a second terminal, from your Brahma checkout:
export PATH="$PWD/.build/debug:$PATH"

# Who is running, what they said, what waits for you.
brahma status
brahma log Acme '#general' --limit 5
brahma log Acme @ceo --limit 5
brahma inbox Acme
