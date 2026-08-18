# Connections and Routing Explanations


The Connections page shows Mihomo's live snapshots. Select a connection to see source,
destination, process, rule, traffic totals, and proxy chain.

## Why this route?

Vela uses evidence reported by Mihomo: rule type and payload, proxy chain, provider chain,
and current runtime rule order.

When one source is unique, Vela shows it. If multiple rules are identical or the
configuration generation changed, Vela reports the source as ambiguous or unavailable.

Vela doesn't promise an offline prediction for a connection that hasn't occurred.
