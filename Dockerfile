# Builds the order desk with Free Pascal on Ubuntu.
FROM ubuntu:24.04

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        fp-compiler fp-units-rtl fp-units-base fp-units-fcl fp-units-db \
        libpq-dev postgresql-client make gdb \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . .
RUN make

CMD ["./bin/orderdesk"]
