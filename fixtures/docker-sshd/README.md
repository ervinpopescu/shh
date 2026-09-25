# Docker OpenSSH Test Fixture

This container provides an OpenSSH 9.x server for optional manual
interoperability checks with `ShhSSH`. The package test suite uses the
in-process `SSHTestServer` and does not require Docker.

## Usage

Build the image:
```bash
docker build -t shh-test-sshd fixtures/docker-sshd
```

Run container:
```bash
docker run -d --rm -p 2222:2222 --name shh-sshd shh-test-sshd
```

Credentials (test-only and intentionally insecure):
- Username: `testuser`
- Password: `testpassword`
- Port: `2222`

Do not expose this container to an untrusted network or reuse these credentials.
The `--rm` run option removes the container when it stops.
