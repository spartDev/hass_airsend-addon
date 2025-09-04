ARG BUILD_FROM
FROM $BUILD_FROM

# Install required packages
RUN apk add --no-cache \
    php8 \
    php8-curl \
    php8-json \
    php8-mbstring \
    php8-openssl \
    curl \
    bash \
    jq \
    procps

# Create necessary directories
RUN mkdir -p /home /share /config /tmp

# Copy data for add-on
COPY hassapi.class.php /home/
COPY callback.php /home/
COPY state_post.sh /home/
COPY states_get.sh /home/
COPY init_reception.sh /home/
COPY test_reception.sh /home/
COPY run.sh /

# Set permissions
RUN chmod a+x /home/state_post.sh \
    && chmod a+x /home/states_get.sh \
    && chmod a+x /home/init_reception.sh \
    && chmod a+x /home/test_reception.sh \
    && chmod a+x /run.sh

# Install AirSendWebService
RUN cd /home \
    && wget -q http://devmel.com/dl/AirSendWebService.tgz \
    && tar -zxvf AirSendWebService.tgz \
    && chmod -R 777 bin \
    && rm AirSendWebService.tgz

# Create symlink for PHP8
RUN ln -sf /usr/bin/php8 /usr/bin/php

# Health check
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:33863/status || exit 1

# Environment variables
ENV RECEPTION_ENABLED=true
ENV DEBUG=0
ENV LOG_LEVEL=INFO

# Start enhanced service with reception support
CMD [ "/run.sh" ]

# Expose port for AirSend communication
EXPOSE 33863