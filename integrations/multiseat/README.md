# EpicVM's MultiSeat credential extension

EpicVM uses MultiSeat's official seat and app launch API. Its admin-only password reveal needs the small source patch in `managed-credential-reveal.patch`, applied to a matching MultiSeat v0.6.7 checkout before building. The patch adds `POST /api/accounts/{username}/credential/reveal` for accounts created by MultiSeat. It does not add credentials to account lists or logs.

The deployed host's MultiSeat API is authenticated and bound to `127.0.0.1:9550`. EpicVM's Windows agent calls it locally. The public EpicVM dashboard exposes the result only through a CSRF-protected admin route with `Cache-Control: no-store` and records the admin, target account, host, and time without storing the password.

Build the patched service with `dotnet publish src/MultiSeat.Service/MultiSeat.Service.csproj -c Release -r win-x64 --self-contained false`. Keep MultiSeat's installed configuration and data. Update only the service binary while no seats are active, restart `MultiSeatService`, and verify its authenticated API before deploying the EpicVM agent. The deployment on September 23, 2026 backed up the prior DLL at `C:\ProgramData\EpicVM\multiseat-service-before-credential-reveal-20260923.dll`.
