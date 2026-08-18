# Troubleshooting Network Problems


## First checks

1. Open Diagnostics.
2. Confirm Mihomo and the Controller are reachable.
3. Confirm the active configuration is valid.
4. Check the actual System Proxy or TUN state.
5. Review the latest transition or rollback result.

Use Diagnostics repair actions rather than broad terminal commands. Vela won't delete
unknown interfaces or routes belonging to other VPN software.

For a safe fallback, use **Restore System Proxy Mode** or **Stop Vela Network Services**.
