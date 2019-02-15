FROM ubuntu:18.04
VOLUME ["/data", "/home"]

RUN useradd -ms /bin/bash coral


RUN DEBIAN_FRONTEND=noninteractive \
    apt-get update && \
    apt-get install -y m4 make ocaml opam llvm-6.0-dev m4 cmake pkg-config

CMD chown coral /home/coral
USER coral
RUN opam init
RUN opam install llvm
