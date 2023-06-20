FROM kong/kong-gateway:latest
USER root

RUN apt-get update && apt-get install -y --no-install-recommends unzip luarocks
COPY ./plugins/oidc /custom-plugins/oidc

WORKDIR /custom-plugins/oidc
RUN luarocks make

COPY ./kong.conf /etc/kong/kong.conf

USER kong