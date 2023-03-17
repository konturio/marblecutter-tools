FROM quay.io/mojodna/gdal:v2.3.x
LABEL maintainer="Seth Fitzsimmons <seth@mojodna.net>"

ARG http_proxy

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update \
  && apt-get upgrade -y \
  && apt-get install -y --no-install-recommends \
    bc \
    ca-certificates \
    curl \
    git \
    jq \
    nfs-common \
    parallel \
    python-pip \
    python-wheel \
    python-setuptools \
    unzip \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/marblecutter-tools

COPY requirements.txt /opt/marblecutter-tools/requirements.txt

ENV CPL_VSIL_CURL_ALLOWED_EXTENSIONS .vrt,.tif,.tiff,.ovr,.msk,.jp2,.img,.hgt
ENV GDAL_DISABLE_READDIR_ON_OPEN TRUE
ENV VSI_CACHE TRUE
ENV VSI_CACHE_SIZE 536870912

ENV LC_ALL C.UTF-8
ENV LANG C.UTF-8

RUN apt-get update
RUN apt-get install -y build-essential checkinstall
RUN apt-get install -y libreadline-gplv2-dev libncursesw5-dev libssl-dev libsqlite3-dev tk-dev libgdbm-dev libc6-dev libbz2-dev
RUN apt-get install -y wget
RUN wget https://www.python.org/ftp/python/3.6.3/Python-3.6.3.tgz
RUN tar -xvf Python-3.6.3.tgz
RUN cd Python-3.6.3 && ./configure && make && make install

RUN pip3 install --upgrade setuptools
RUN pip3 install rasterio haversine cython awscli

COPY bin/* /opt/marblecutter-tools/bin/

RUN ln -s /opt/marblecutter-tools/bin/* /usr/local/bin/ && mkdir -p /efs
