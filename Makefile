include version.mk
ERLANG_ROOT := $(shell erl -eval 'io:format("~s", [code:root_dir()])' -s init stop -noshell)
APPNAME = fyler
APPDIR=$(ERLANG_ROOT)/lib/$(APPNAME)-$(VERSION)
ERL_LIBS:=apps:deps


ERL=erl +A 4 +K true
REBAR := which rebar || ./rebar


all: deps compile

update:
	git pull

deps:
	@$(REBAR) get-deps

compile:
	@$(REBAR) compile

release: clean compile
	@$(REBAR) generate force=1
	chmod +x $(APPNAME)/bin/$(APPNAME)

test-core:
	@$(REBAR) skip_deps=true eunit apps=fyler suites=fyler_server,fyler_uploader,aws_cli,fyler_utils

test-docs:
	@$(REBAR) skip_deps=true eunit suites=docs_conversions_tests

test-video:
	@$(REBAR) skip_deps=true eunit suites=video_conversions_tests

clean:
	@$(REBAR) clean

db_setup:
	scripts/setup_db.erl

handlers:
	scripts/gen_handlers_list.erl

run-server:
	ERL_LIBS=apps:deps erl -args_file files/vm.args.sample -sasl errlog_type error -boot  start_sasl -s $(APPNAME) -embedded -config files/app.config  -fyler role server

run-pool:
	ERL_LIBS=apps:deps erl -args_file files/vm.args.pool.sample -sasl errlog_type error -boot start_sasl -s $(APPNAME) -embedded -config files/app.pool.config  -fyler role pool

run-pool-video:
	ERL_LIBS=apps:deps erl -args_file files/vm.args.video.sample -sasl errlog_type error -boot start_sasl -s $(APPNAME) -embedded -config files/app.video.config  -fyler role pool

clean-tmp:
	cd tmp && ls | xargs rm && cd ..

version:
	echo "VERSION=$(VER)" > version.mk
	git add version.mk
	git commit -m "Version $(VER)"
	git tag -a v$(VER) -m "version $(VER)"
