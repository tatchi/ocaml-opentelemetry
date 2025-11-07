# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an OCaml implementation of OpenTelemetry providing APIs for instrumenting server software with traces, metrics, and logs. The library can communicate with OpenTelemetry collectors like Jaeger and DataDog.

## Common Development Commands

### Building
```bash
make all          # Build everything with release profile
dune build @all   # Build all targets
```

### Testing
```bash
make test         # Run all tests
dune runtest      # Run tests directly with dune
```

### Development
```bash
make format       # Format code using ocamlformat
make watch        # Watch build (defaults to @all target)
make clean        # Clean build artifacts
```

### Code Quality
- Formatting is done with `ocamlformat` (version 0.27.x required)
- Use `make format` to auto-format code

## Architecture

### Core Components

**Core Library (`src/core/`)** - Main OpenTelemetry API
- `opentelemetry.ml` - Main entry point with all public modules
- Contains trace IDs, span IDs, span contexts, scopes, collectors
- Defines the `Collector.BACKEND` interface for pluggable backends

**Client Implementations**
- `src/client-ocurl/` - HTTP client using cURL (synchronous, thread-based)
- `src/client-ocurl-lwt/` - HTTP client using ezcurl-lwt (async Lwt-based)
- `src/client-cohttp-lwt/` - HTTP client using cohttp-lwt (async Lwt-based)
- All implement the collector backend interface for sending telemetry data

**Protocol Layer (`src/proto/`)** 
- Generated protobuf bindings for OpenTelemetry protocol
- Handles serialization of traces, metrics, logs to wire format

**Context Management (`src/ambient-context/`)**
- Provides ambient/implicit context tracking using thread-local or async storage
- Supports Lwt and Eio for async context propagation
- Vendored version of the `ambient-context` library

### Key Patterns

**Instrumentation API**: Primary user-facing API is `Opentelemetry.Trace.with_` for span creation:
```ocaml
let@ scope = Otel.Trace.with_ "operation_name" ~attrs:["key", `String "value"] in
(* work happens here *)
```

**Backend Architecture**: Uses a pluggable collector backend system - the core library defines interfaces, client libraries implement them.

**Ambient Scopes**: Uses ambient context to automatically propagate trace/span context across function calls without explicit parameter passing.

**Configuration**: Environment-variable driven configuration (OTEL_* variables) with programmatic overrides.

## Library Structure

- `opentelemetry` - Core instrumentation API (main library)
- `opentelemetry-lwt` - Lwt-compatible extensions
- `opentelemetry-client-ocurl` - cURL-based HTTP collector client (thread-based)
- `opentelemetry-client-ocurl-lwt` - ezcurl-lwt-based HTTP collector client (Lwt async)
- `opentelemetry-client-cohttp-lwt` - cohttp-lwt HTTP collector client (Lwt async)
- `opentelemetry-cohttp-lwt` - HTTP server instrumentation for cohttp
- `opentelemetry.trace` - Integration with the `trace` library (optional)

## Testing

Tests are organized by component:
- `tests/core/` - Core functionality tests
- `tests/client/` - Client library tests  
- `tests/ocurl/` and `tests/cohttp/` - HTTP client tests

Use `make test` or `dune runtest` to run the full test suite.