# syntax=docker/dockerfile:1
ARG MOONBIT_IMAGE=ghcr.io/gaato/moonbit:0.10.21-06da1ed44
FROM ${MOONBIT_IMAGE} AS build
RUN moon update
COPY . ./
RUN moon build --target native --release src/main && \
    install -D "$(find _build/native/release/build -path '*/main/main.exe' -print -quit)" /out/api

FROM gcr.io/distroless/base-debian13
COPY --from=build /out/api /api
USER nonroot:nonroot
ENV LISTEN_ADDR=0.0.0.0:8080
EXPOSE 8080
ENTRYPOINT ["/api"]
