FROM alpine:3.19

RUN apk add --no-cache openssh-server bash

RUN ssh-keygen -A

RUN adduser -D -s /bin/bash testuser && \
    echo "testuser:testpassword" | chpasswd

COPY sshd_config /etc/ssh/sshd_config

RUN mkdir -p /home/testuser/.ssh && \
    chmod 700 /home/testuser/.ssh && \
    chown -R testuser:testuser /home/testuser/.ssh

EXPOSE 2222

CMD ["/usr/sbin/sshd", "-D", "-e"]
