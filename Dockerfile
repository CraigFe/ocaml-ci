FROM ocurrent/opam:debian-10-ocaml-4.08 AS build
RUN sudo apt-get update && sudo apt-get install m4 pkg-config libsqlite3-dev libgmp-dev -y --no-install-recommends
RUN cd ~/opam-repository && git pull origin master && git reset --hard b70af589a3a2e7aa2202b499b8c669fa4e51bf42 && opam update
COPY --chown=opam \
	ocurrent/current.opam \
	ocurrent/current_web.opam \
	ocurrent/current_docker.opam \
	ocurrent/current_git.opam \
	ocurrent/current_github.opam \
	/src/ocurrent/
RUN opam pin -y add /src/ocurrent
COPY --chown=opam ocaml-ci.opam /src/
WORKDIR /src
RUN opam install -y --deps-only .
ADD --chown=opam . .
RUN opam config exec -- dune build ./_build/install/default/bin/ocaml-ci

FROM debian:10
RUN apt-get update && apt-get install curl gnupg2 dumb-init git graphviz libsqlite3-dev ca-certificates netbase -y --no-install-recommends
RUN curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -
RUN echo 'deb [arch=amd64] https://download.docker.com/linux/debian buster stable' >> /etc/apt/sources.list
RUN apt-get update && apt-get install docker-ce -y --no-install-recommends
WORKDIR /var/lib/ocurrent
ENTRYPOINT ["dumb-init", "/usr/local/bin/ocaml-ci"]
COPY --from=build /src/_build/install/default/bin/ocaml-ci /usr/local/bin/
