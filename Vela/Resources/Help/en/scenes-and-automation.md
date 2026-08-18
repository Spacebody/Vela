# Scenes and Automation


A Scene can choose a configuration, backend, Mihomo mode, proxy selections, and a Scene
configuration layer.

Triggers can use interface type, an optional current Wi-Fi name, local time, power source,
and constrained or expensive network state.

Vela requests Location permission only when you add a Wi-Fi-name trigger. It reads the
current Wi-Fi name, doesn't scan nearby networks, and doesn't read BSSID. The exact name
is stored in Keychain.

Debounce, a stability window, cooldown, and manual lock prevent rapid switching.
