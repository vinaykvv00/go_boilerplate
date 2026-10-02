# Config Package — Explained for Beginners

This file explains **everything** about the `config` package: the concepts first, then the code, then how it connects to the rest of the backend.

> **Read order:** Concepts → `config.go` → `observability.go` → "How it connects"

---

## Part 1 — The Big Idea (read this first)

### What is "config" in a backend?

Every app needs **settings** to run. Your phone needs your WiFi password, your language, your theme. A backend needs:

- Which **port** to listen on (`8080`?)
- **Database** credentials (host, user, password)
- **Secret keys** (for signing auth tokens)
- **Redis** address (for caching)
- **Log level** (debug / info / error)

These values are **different in different environments**:

| Environment | Database | Log level | Secrets |
|---|---|---|---|
| Your laptop (dev) | `localhost` | `debug` (verbose) | fake ones |
| Staging server | test DB | `info` | test keys |
| Production | real DB | `info` | **real keys** |

**The golden rule:** never hardcode these in your source code. They live in **environment variables** (or a `.env` file), and your code reads them at startup.

### Why? (the 3 reasons)

1. **Security** — passwords & keys must NOT be committed to Git. They live in `.env` files that are gitignored.
2. **Portability** — write code once, run it anywhere (local, Docker, cloud) just by changing config.
3. **Separation** — changing a port shouldn't require recompiling the app. Config is *data*, not *logic*.

### The mental model

```
.env file / environment variables   ← where the VALUES live
        │
        │  (koanf reads them)
        ▼
Config struct (typed + validated)   ← single source of truth in code
        │
        │  (passed to everything)
        ▼
server / database / auth / logger   ← the rest of the app
```

Your code **never** calls `os.Getenv()` directly. It only touches the clean, validated `Config` object. That keeps code clean, testable, and safe.

---

## Part 2 — Go Concepts You MUST Know First

These are the building blocks used everywhere in this file. If you understand these, the code becomes obvious.

### 1. Structs — a "group of fields"

A struct is a way to group related data together.

```go
type ServerConfig struct {
	Port string
}
```

Think of it like a form with labeled boxes. `ServerConfig` has a box called `Port`.

### 2. Struct tags — little labels in backticks

```go
type ServerConfig struct {
	Port string `koanf:"port" validate:"required"`
}
```

The backtick part `` `koanf:"port" validate:"required"` `` is a **tag** — metadata attached to the field. It doesn't change the field's value; it tells *other libraries* how to treat it.

- `koanf:"port"` → "when reading config, this field maps to the key `port`"
- `validate:"required"` → "this field MUST have a value, or the app should refuse to start"

Tags are how libraries like koanf and validator "talk to" your struct without you writing glue code.

### 3. Pointers — `*Config` and `&Config`

- `*Config` means "a pointer to a Config" — a reference/address, not a copy.
- `&Config{...}` creates a Config and gives you its address.

Why pointers? So that when you pass config around, you're not copying the whole thing, and changes are shared. Also, a pointer can be `nil` (nothing) — which is used for *optional* config (see `Observability *ObservabilityConfig`).

### 4. Methods with pointer receivers

```go
func (c *ObservabilityConfig) IsProduction() bool {
	return c.Environment == "production"
}
```

This attaches a function to the `ObservabilityConfig` type. Now you can call `config.Observability.IsProduction()`. The `(c *ObservabilityConfig)` part is the "receiver" — it's like `this` in other languages.

### 5. Blank import — `_ "github.com/joho/godotenv/autoload"`

```go
_ "github.com/joho/godotenv/autoload"
```

Normally you import a package to use its functions. A **blank import** (`_`) means: "I don't call anything from this package directly, but I want its `init()` function to run at startup." The godotenv package's `init()` automatically loads your `.env` file into environment variables — before anything else runs. That's why it's a blank import.

### 6. Environment variables

Key-value pairs provided by the OS, e.g. `BOILERPLATE_SERVER_PORT=8080`. In Go you'd read them with `os.Getenv("...")`. This package uses a library (koanf) to do that in a smarter way.

### 7. `time.Duration`

A type representing a length of time (nanoseconds underneath). `100 * time.Millisecond` = 100ms. Used for timeouts.

---

## Part 3 — The Libraries (what each one does)

| Library | Purpose |
|---|---|
| **koanf** | Reads config from many sources (env vars, files, flags) and maps them into your structs. The "config loader" of this project. |
| **godotenv** | Loads a `.env` file into environment variables (so you don't have to export them manually). |
| **validator** | Validates structs using the `validate:"..."` tags. Fails fast if required fields are missing. |
| **zerolog** | A fast, structured (JSON) logger for Go. Used here to log errors during config loading. |

---

## Part 4 — `config.go` Explained Line by Line

### The imports

```go
import (
	"os"          // standard: access OS stuff (stderr, env vars)
	"strings"     // standard: string helpers (ToLower, TrimPrefix)

	"github.com/go-playground/validator/v10"          // validation
	_ "github.com/joho/godotenv/autoload"             // auto-load .env
	"github.com/knadh/koanf/providers/env"            // koanf: read from env vars
	"github.com/knadh/koanf/v2"                       // koanf: core library
	"github.com/rs/zerolog"                           // logging
)
```

### The structs — the "shape" of your config

```go
type Config struct {
	Primary       Primary              `koanf:"primary" validate:"required"`
	Server        ServerConfig         `koanf:"server" validate:"required"`
	Database      DatabaseConfig       `koanf:"database" validate:"required"`
	Auth          AuthConfig           `koanf:"auth" validate:"required"`
	Redis         RedisConfig          `koanf:"redis" validate:"required"`
	Observability *ObservabilityConfig `koanf:"observability"`
}
```

This is the **top-level contract**: "my app needs these 6 groups of settings."

- `Primary` — the environment name (`development` / `production`).
- `Server` — port + timeouts + CORS.
- `Database` — connection details + connection pool settings.
- `Auth` — the secret key for signing tokens.
- `Redis` — cache server address.
- `Observability` — logging/monitoring settings. Note it's a **pointer** (`*ObservabilityConfig`) and has **no** `validate:"required"` → it's **optional** (gets defaults).

Each nested struct is a "sub-form":

```go
type ServerConfig struct {
	Port               string   `koanf:"port" validate:"required"`
	ReadTimeout        int      `koanf:"read_timeout" validate:"required"`
	WriteTimeout       int      `koanf:"write_timeout" validate:"required"`
	IdleTimeout        int      `koanf:"idle_timeout" validate:"required"`
	CORSAllowedOrigins []string `koanf:"cors_allowed_origins" validate:"required"`
}
```

> **Note:** `DatabaseConfig.Password` has NO `validate:"required"` — passwords can be empty in dev. That's a deliberate choice.

### `LoadConfig()` — the single entry point

```go
func LoadConfig() (*Config, error) {
```

Every other part of the app calls this **once** at startup to get a fully-populated, validated `Config`.

**Step 1 — create a logger for config-loading errors:**

```go
logger := zerolog.New(zerolog.ConsoleWriter{Out: os.Stderr}).With().Timestamp().Logger()
```

Creates a logger that writes human-readable logs to stderr with timestamps. Used only to report config problems.

**Step 2 — create the koanf instance:**

```go
k := koanf.New(".")
```

`koanf.New(".")` creates a config loader. The `"."` is the delimiter used to split keys into nested paths (e.g. `server.port`).

**Step 3 — load from environment variables:**

```go
err := k.Load(env.Provider("BOILERPLATE_", ".", func(s string) string {
	return strings.ToLower(strings.TrimPrefix(s, "BOILERPLATE_"))
}), nil)
```

This is the **core mechanism**. It reads every env var starting with `BOILERPLATE_`, strips that prefix, and lowercases it. So:

| Env variable | koanf key | Maps to |
|---|---|---|
| `BOILERPLATE_SERVER_PORT` | `server.port` | `Config.Server.Port` |
| `BOILERPLATE_DATABASE_HOST` | `database.host` | `Config.Database.Host` |
| `BOILERPLATE_AUTH_SECRET_KEY` | `auth.secret_key` | `Config.Auth.SecretKey` |

The `_` in env vars becomes `.` nesting in the struct. That's why the structs are nested — they mirror the env var naming.

**Step 4 — unmarshal into the struct:**

```go
mainConfig := &Config{}
err = k.Unmarshal("", mainConfig)
```

Converts the flat map of env vars into the nested `Config` struct. The `koanf:"..."` tags tell it where each value goes.

**Step 5 — validate (fail fast):**

```go
validate := validator.New()
err = validate.Struct(mainConfig)
```

Checks all `validate:"required"` tags. If anything required is missing, the app **crashes immediately** with a clear error — instead of running with broken settings and failing mysteriously later. This is the **fail-fast principle**.

**Step 6 — observability defaults:**

```go
if mainConfig.Observability == nil {
	mainConfig.Observability = DefaultObservabilityConfig()
}
```

Observability is optional, so if not provided, fill it with sensible defaults (from `observability.go`).

**Step 7 — override service name & environment:**

```go
mainConfig.Observability.ServiceName = "boilerplate"
mainConfig.Observability.Environment = mainConfig.Primary.Env
```

Forces the service name and takes the environment from `Primary.Env` (the single source of truth for "which env am I in?").

**Step 8 — validate observability:**

```go
if err := mainConfig.Observability.Validate(); err != nil {
	logger.Fatal().Err(err).Msg("invalid observability config")
}
```

Runs the custom validation defined in `observability.go`.

**Step 9 — return:**

```go
return mainConfig, nil
```

Returns the fully-loaded, validated config. The rest of the app uses this.

---

## Part 5 — `observability.go` Explained

### What is "observability"?

Observability = **how you SEE what your app is doing** while it runs. Three pillars:

1. **Logs** — text records of events ("user logged in", "query took 2s").
2. **Metrics** — numbers (request count, error rate, latency).
3. **Traces** — the path of a single request through your services.

This file configures **logging** and **New Relic** (a monitoring service that collects logs/traces/errors in production).

### The structs

```go
type ObservabilityConfig struct {
	ServiceName  string             `koanf:"service_name" validate:"required"`
	Environment  string             `koanf:"environment" validate:"required"`
	Logging      LoggingConfig      `koanf:"logging" validate:"required"`
	NewRelic     NewRelicConfig     `koanf:"new_relic" validate:"required"`
	HealthChecks HealthChecksConfig `koanf:"health_checks" validate:"required"`
}
```

- `ServiceName` — what this service is called (shows up in New Relic).
- `Environment` — dev/prod (drives log level & behavior).
- `Logging` — log level, format, slow-query threshold.
- `NewRelic` — license key + feature toggles.
- `HealthChecks` — whether to ping database/redis periodically.

```go
type LoggingConfig struct {
	Level              string        `koanf:"level" validate:"required"`
	Format             string        `koanf:"format" validate:"required"`
	SlowQueryThreshold time.Duration `koanf:"slow_query_threshold"`
}
```

- `Level` — `debug` (most verbose) → `info` → `warn` → `error` (least).
- `Format` — `json` (machine-readable, for prod) or `pretty` (human-readable, for dev).
- `SlowQueryThreshold` — if a DB query takes longer than this, log a warning.

```go
type NewRelicConfig struct {
	LicenseKey                string `koanf:"license_key" validate:"required"`
	AppLogForwardingEnabled   bool   `koanf:"app_log_forwarding_enabled"`
	DistributedTracingEnabled bool   `koanf:"distributed_tracing_enabled"`
	DebugLogging              bool   `koanf:"debug_logging"`
}
```

- `LicenseKey` — your New Relic account key (empty in dev = New Relic disabled).
- `AppLogForwardingEnabled` — send app logs to New Relic.
- `DistributedTracingEnabled` — trace requests across services.
- `DebugLogging` — New Relic's own debug logs (off by default to avoid noise).

```go
type HealthChecksConfig struct {
	Enabled  bool          `koanf:"enabled"`
	Interval time.Duration `koanf:"interval" validate:"min=1s"`
	Timeout  time.Duration `koanf:"timeout" validate:"min=1s"`
	Checks   []string      `koanf:"checks"`
}
```

- `Enabled` — turn health checks on/off.
- `Interval` — how often to check (min 1s).
- `Timeout` — how long to wait before giving up (min 1s).
- `Checks` — which dependencies to check (`database`, `redis`).

### `DefaultObservabilityConfig()` — the fallback

```go
func DefaultObservabilityConfig() *ObservabilityConfig {
	return &ObservabilityConfig{
		ServiceName: "boilerplate",
		Environment: "development",
		Logging: LoggingConfig{
			Level:              "info",
			Format:             "json",
			SlowQueryThreshold: 100 * time.Millisecond,
		},
		NewRelic: NewRelicConfig{
			LicenseKey:                "",
			AppLogForwardingEnabled:   true,
			DistributedTracingEnabled: true,
			DebugLogging:              false,
		},
		HealthChecks: HealthChecksConfig{
			Enabled:  true,
			Interval: 30 * time.Second,
			Timeout:  5 * time.Second,
			Checks:   []string{"database", "redis"},
		},
	}
}
```

Returns a ready-made config with sane defaults, so the app works even with zero observability env vars. Note `LicenseKey: ""` → New Relic effectively disabled in dev.

### `Validate()` — custom validation

```go
func (c *ObservabilityConfig) Validate() error {
	if c.ServiceName == "" {
		return fmt.Errorf("service_name is required")
	}

	validLevels := map[string]bool{
		"debug": true, "info": true, "warn": true, "error": true,
	}
	if !validLevels[c.Logging.Level] {
		return fmt.Errorf("invalid logging level: %s (must be one of: debug, info, warn, error)", c.Logging.Level)
	}

	if c.Logging.SlowQueryThreshold < 0 {
		return fmt.Errorf("logging slow_query_threshold must be non-negative")
	}

	return nil
}
```

Extra validation that the generic `validator` can't easily express:
- Service name must not be empty.
- Log level must be one of the 4 valid values.
- Slow-query threshold can't be negative.

Returns `nil` if everything is OK, otherwise an error describing the problem.

### `GetLogLevel()` — environment-aware log level

```go
func (c *ObservabilityConfig) GetLogLevel() string {
	switch c.Environment {
	case "production":
		if c.Logging.Level == "" {
			return "info"
		}
	case "development":
		if c.Logging.Level == "" {
			return "debug"
		}
	}
	return c.Logging.Level
}
```

If no level is set, **derive it from the environment**: production → `info` (quiet), development → `debug` (verbose). This is the pattern of *deriving behavior from the environment*.

### `IsProduction()` — a handy helper

```go
func (c *ObservabilityConfig) IsProduction() bool {
	return c.Environment == "production"
}
```

A tiny helper other packages call to branch on environment, e.g. "use JSON logs in prod, pretty logs in dev."

---

## Part 6 — How This Connects to the Rest of the Backend

The config package is the **foundation** — everything else depends on it.

```
main.go
   │
   └── LoadConfig()  ──►  *Config  (fully loaded + validated)
                              │
        ┌─────────────────────┼──────────────────────┐
        ▼                     ▼                      ▼
   server package        database package        logger package
   (reads Server)        (reads Database)        (reads Observability)
        │                     │                      │
        ▼                     ▼                      ▼
   HTTP port, timeouts    connection string      log level, format,
   CORS origins           + pool settings        New Relic, health checks
```

Concrete examples of how each part will use it:

| Package | Uses | For |
|---|---|---|
| `server` | `config.Server.Port`, `ReadTimeout`, `CORSAllowedOrigins` | Starting the HTTP server |
| `database` | `config.Database.Host`, `Port`, `User`, `Password`, `MaxOpenConns` | Building the DB connection + pool |
| `auth` | `config.Auth.SecretKey` | Signing/verifying JWT tokens |
| `redis` | `config.Redis.Address` | Connecting to the cache |
| `logger` | `config.Observability.*` | Setting log level, format, New Relic |
| `middleware` | `config.Observability.IsProduction()` | Env-specific behavior (e.g. CORS, error responses) |

### The flow in `main.go` (what will happen)

```go
func main() {
	cfg, err := config.LoadConfig()   // 1. load everything
	if err != nil {
		// 2. if config is bad, crash now (fail fast)
	}

	// 3. pass cfg to everything else
	db := database.New(cfg.Database)
	logger := logger.New(cfg.Observability)
	server := server.New(cfg.Server, db, logger)
	server.Run()
}
```

---

## Part 7 — Quick Reference Cheat Sheet

| Concept | Meaning |
|---|---|
| Struct | A group of related fields |
| Struct tag | Metadata in backticks that libraries read |
| `koanf:"x"` | Maps this field to config key `x` |
| `validate:"required"` | This field must have a value |
| `*Type` | Pointer (reference) — can be `nil` |
| `&Type{...}` | Create a value and take its address |
| `(c *Type) Method()` | Method attached to the type (like `this`) |
| `_ "pkg"` | Blank import — run the package's `init()` only |
| Env var | OS-level key-value setting |
| `time.Duration` | A length of time |
| Fail-fast | Crash at startup if config is invalid |
| Observability | Logs + metrics + traces (seeing what the app does) |

---

## Part 8 — Try It Yourself

1. Create a `.env` file in `backend/` with:
   ```bash
   BOILERPLATE_PRIMARY_ENV=development
   BOILERPLATE_SERVER_PORT=8080
   BOILERPLATE_SERVER_READ_TIMEOUT=10
   BOILERPLATE_SERVER_WRITE_TIMEOUT=10
   BOILERPLATE_SERVER_IDLE_TIMEOUT=60
   BOILERPLATE_SERVER_CORS_ALLOWED_ORIGINS=http://localhost:3000
   BOILERPLATE_DATABASE_HOST=localhost
   BOILERPLATE_DATABASE_PORT=5432
   BOILERPLATE_DATABASE_USER=postgres
   BOILERPLATE_DATABASE_PASSWORD=postgres
   BOILERPLATE_DATABASE_NAME=boilerplate
   BOILERPLATE_DATABASE_SSL_MODE=disable
   BOILERPLATE_DATABASE_MAX_OPEN_CONNS=25
   BOILERPLATE_DATABASE_MAX_IDLE_CONNS=25
   BOILERPLATE_DATABASE_CONN_MAX_LIFETIME=300
   BOILERPLATE_DATABASE_CONN_MAX_IDLE_TIME=60
   BOILERPLATE_REDIS_ADDRESS=localhost:6379
   BOILERPLATE_AUTH_SECRET_KEY=dev-secret-key
   ```

2. In `main.go`, temporarily call `config.LoadConfig()` and print the result to see it work:
   ```go
   package main

   import (
       "fmt"
       "github.com/vinaykvv00/go-boilerplate/internal/config"
   )

   func main() {
       cfg, err := config.LoadConfig()
       if err != nil {
           panic(err)
       }
       fmt.Printf("Server port: %s\n", cfg.Server.Port)
       fmt.Printf("DB host: %s\n", cfg.Database.Host)
       fmt.Printf("Env: %s\n", cfg.Primary.Env)
   }
   ```

3. **Experiment:** remove a required env var (e.g. `BOILERPLATE_SERVER_PORT`) and run again — you'll see the app **fail fast** with a validation error. That's the fail-fast principle in action.
