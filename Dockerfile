FROM kong/kong-gateway:latest
USER root
RUN apt-get update && apt-get install -y --no-install-recommends unzip


COPY kong.conf /etc/kong/
RUN luarocks install kong-oidc

#COPY ./plugins/oidc /custom-plugins/oidc

#WORKDIR /custom-plugins/oidc
#RUN luarocks make

USER kong