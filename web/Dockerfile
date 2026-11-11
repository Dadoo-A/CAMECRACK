# Small web service: serves the control page, relays PTZ commands and boot sounds
# to the camera (its web page; telnet 24 in SD mode). Python stdlib + ffmpeg.
FROM python:3.12-alpine

# ffmpeg converts uploaded sounds to the camera format (MP3 8 kHz mono)
RUN apk add --no-cache ffmpeg

WORKDIR /app
COPY server.py camecrack.html ./

ENV CAMERA_IP="" \
    TELNET_PORT="24" \
    HTTP_PORT="8787" \
    PTZCTL="auto" \
    PTZ_CONF="auto"

EXPOSE 8787
CMD ["python", "-u", "server.py"]
