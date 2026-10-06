# Minimal Confluent license status exporter: kcat + busybox httpd (from busybox-extras)
FROM alpine:3.22

RUN apk add --no-cache kcat busybox-extras && mkdir /www && chown nobody /www

COPY exporter.sh /usr/local/bin/exporter.sh
RUN chmod +x /usr/local/bin/exporter.sh

USER nobody
EXPOSE 9101
ENTRYPOINT ["/usr/local/bin/exporter.sh"]
