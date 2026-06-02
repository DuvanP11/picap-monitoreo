FROM alpine:latest

ARG GITHUB_AUTH
ARG FILE_DIR
ARG PATH_HELM
ARG IMAGE_NAME

# Instalación de paquetes necesarios
RUN apk update && \
    apk add --no-cache \
    git \
    yq

# Clonar el repositorio
RUN git clone https://$GITHUB_AUTH@github.com/picap-inc/secrets.git /app
WORKDIR /app/$FILE_DIR

# Modificar el archivo utilizando yq
RUN yq -i ".image.repository = \"$IMAGE_NAME\"" $PATH_HELM

# Configurar Git
RUN git config --global user.email "it@picap.co" && \
    git config --global user.name "It Picap"

# Añadir cambios, realizar commit y hacer push.
# Tolerante a 2 problemas comunes:
#   1. "nothing to commit" (re-runs / SHA ya bumpeado) -> skip commit.
#   2. "remote rejected" por race condition con otros workflows pusheando
#      al mismo secrets/ al mismo tiempo -> pull --rebase + retry hasta 5x.
RUN git add . && \
    (git diff --cached --quiet || git commit -m "New image version $IMAGE_NAME") && \
    ( \
      git push origin main || \
      ( echo "[retry 1/5] push rechazado, rebase+retry en 2s..." && sleep 2 && git pull --rebase origin main && git push origin main ) || \
      ( echo "[retry 2/5] push rechazado, rebase+retry en 4s..." && sleep 4 && git pull --rebase origin main && git push origin main ) || \
      ( echo "[retry 3/5] push rechazado, rebase+retry en 8s..." && sleep 8 && git pull --rebase origin main && git push origin main ) || \
      ( echo "[retry 4/5] push rechazado, rebase+retry en 16s..." && sleep 16 && git pull --rebase origin main && git push origin main ) || \
      ( echo "[retry 5/5] push rechazado, rebase+retry en 30s..." && sleep 30 && git pull --rebase origin main && git push origin main ) \
    )

# Limpiar paquetes innecesarios
RUN apk del git yq && \
    rm -rf /var/cache/apk/* \
    rm -rf /app/*

CMD ["sh"]
