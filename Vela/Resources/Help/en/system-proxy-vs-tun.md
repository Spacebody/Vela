# System Proxy and TUN


## System Proxy

System Proxy configures macOS HTTP, HTTPS, and SOCKS settings. It is lightweight, but
applications that ignore system proxy settings may connect directly.

## TUN

TUN routes more device traffic through Mihomo and requires Vela's signed privileged
component.

Vela treats System Proxy and TUN as mutually exclusive. Switching is transactional: if
the target mode fails, Vela attempts to restore the previous healthy mode.

Start with System Proxy. Use TUN when you need broader traffic coverage or UDP handling.
