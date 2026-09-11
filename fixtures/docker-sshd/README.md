# Docker OpenSSH Test Fixture

This container provides an OpenSSH 9.x server configured for integration testing `ShhSSH`.

## Usage

Build the image:
```bash
docker build -t shh-test-sshd fixtures/docker-sshd
```

Run container:
```bash
docker run -d --rm -p 2222:2222 --name shh-sshd shh-test-sshd
```

Credentials:
- Username: `testuser`
- Password: `testpassword`
- Port: `2222`
