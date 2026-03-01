# DevCollab

A developer collaboration and project tracking API built with Spring Boot, Keycloak, and React.

## Tech Stack

**Backend:** Java 21, Spring Boot 3, Spring Security, Spring Cloud Gateway, JPA/Hibernate, MySQL

**Auth:** Keycloak 25 (OAuth2 / OIDC)

**Frontend:** React, Vite, Axios

**Infrastructure:** Docker, Docker Compose

## Architecture

```
React (3000) → Gateway (8080) → Auth Service (8081)
                             → Core Service (8082)

Infrastructure (Docker):
  Keycloak (8180) — Identity Provider
  MySQL (3306)    — devcollab_auth + devcollab_core
```

## Prerequisites

- Java 21
- Maven
- Docker Desktop
- Node.js 18+

## Running Locally

**1. Start infrastructure**

```bash
docker-compose up -d
```

**2. Set up Keycloak**

Open `http://localhost:8180`, log in with `admin/admin`, switch to the `devcollab` realm (auto-imported). Create two test users — alice and bob — with password `password123`.

**3. Start services**

Run each Spring Boot service from IntelliJ with profile `local`:

- Gateway on port 8080
- Auth Service on port 8081
- Core Service on port 8082

**4. Start frontend**

```bash
cd frontend
npm install
npm run dev
```

Open `http://localhost:3000`.

## Security Model

Authentication is delegated to Keycloak via OAuth2 Authorization Code flow. The auth service sets a JWT in an HttpOnly cookie after login. The core service validates the JWT on every request and resolves permissions dynamically from the database via a three-layer RBAC model: User → Role → Permission.

Permissions are seeded from `permissions.json` on startup. Four roles are available per project: OWNER, ADMIN, DEVELOPER, VIEWER.

## API Documentation

Swagger UI is available in local profile only: `http://localhost:8082/swagger-ui.html`

## Environment Variables

Core service expects these in production:

```
MYSQL_HOST, MYSQL_PORT, MYSQL_USER, MYSQL_PASSWORD
KEYCLOAK_ISSUER_URI
API_KEY
```
