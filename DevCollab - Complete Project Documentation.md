# DevCollab — Complete Project Documentation

---

## Table of Contents

1. Project Overview
2. Architecture
3. Technology Stack
4. Repository Structure
5. Infrastructure Setup
6. Backend Services
7. Frontend
8. Security Model
9. API Reference
10. Database Schema
11. Running Locally
12. Contributing Guidelines

---

## 1. Project Overview

DevCollab is a developer collaboration and project tracking platform built for small to medium software consultancies. It allows teams to manage projects, track issues, and control access through a role-based permission system.

The platform solves a specific problem: consultancies running multiple client projects simultaneously need a lightweight way to manage work without the overhead of enterprise tools like Jira. DevCollab provides project isolation (members of Project A cannot see Project B unless explicitly added), fine-grained role-based access control within each project, and a powerful filtering and search system for issue management.

### What the System Does

A user logs in with their company credentials through Keycloak. They see only the projects they are members of. Within each project, their role determines what actions they can take. An Owner has full control. An Admin can manage the project and members. A Developer can create and work on issues. A Viewer has read-only access.

Issues move through a defined lifecycle: OPEN → IN_PROGRESS → IN_REVIEW → DONE → CLOSED. Invalid transitions are rejected. Issues can be filtered by status, priority, type, assignee, reporter, due date range, and title search. Results are paginated and sortable.

### What the System Does Not Do

DevCollab intentionally excludes comments on issues, file attachments, email notifications, and real-time updates. These are Phase 2 features. The current scope is deliberately narrow to ensure the implemented features are done correctly.

---

## 2. Architecture

### High-Level Architecture

```
Browser / React Frontend (port 3000)
            │
            │ All requests go through gateway
            ▼
┌─────────────────────────────────────┐
│         API Gateway (port 8080)     │
│         Spring Cloud Gateway        │
│                                     │
│  Responsibilities:                  │
│  - Route requests by URL prefix     │
│  - Inject correlation IDs           │
│  - Enforce rate limiting            │
│  - Handle CORS for browser clients  │
│  - Forward headers downstream       │
│                                     │
│  Does NOT:                          │
│  - Validate JWTs                    │
│  - Check permissions                │
│  - Know about domain concepts       │
└──────────┬──────────────┬───────────┘
           │              │
    /auth/**        /api/**
           │              │
           ▼              ▼
┌──────────────┐  ┌────────────────────────────────────┐
│ Auth Service │  │           Core Service             │
│ (port 8081)  │  │           (port 8082)              │
│              │  │                                    │
│ OAuth2       │  │  All domain logic lives here       │
│ Client       │  │                                    │
│              │  │  Security:                         │
│ Talks to     │  │  - JWT validation (Resource Server)│
│ Keycloak     │  │  - Dynamic permission resolution   │
│              │  │  - API Key authentication          │
│ Sets JWT     │  │  - Method-level @PreAuthorize      │
│ cookie on    │  │                                    │
│ successful   │  │  Domain:                           │
│ login        │  │  - Projects                        │
│              │  │  - Issues (with filtering)         │
│              │  │  - Members                         │
│              │  │  - RBAC (Users, Roles, Permissions)│
└──────────────┘  └────────────────────────────────────┘
       │                        │
       │                        │
       ▼                        ▼
┌─────────────┐        ┌─────────────────┐
│devcollab_   │        │ devcollab_core  │
│auth (MySQL) │        │ (MySQL)         │
└─────────────┘        └─────────────────┘
            \                  /
             \                /
              ▼              ▼
         ┌──────────────────────┐
         │  MySQL (port 3306)   │
         │  Docker Container    │
         │                      │
         │  Two separate        │
         │  databases in one    │
         │  MySQL instance      │
         └──────────────────────┘

         ┌──────────────────────┐
         │  Keycloak (port 8180)│
         │  Docker Container    │
         │                      │
         │  Identity Provider   │
         │  devcollab realm     │
         │  Issues JWT tokens   │
         └──────────────────────┘
```

### Request Flow — Authenticated API Call

This is the complete journey of a request from the browser to the database and back. Understanding this flow is essential for contributing to the project.

```
1. Browser sends:
   GET http://localhost:8080/api/projects
   Cookie: JWT_TOKEN=eyJhbGciOiJSUzI1NiJ9...

2. Gateway receives the request
   CorrelationIdFilter runs:
     Checks for X-Correlation-ID header
     Not present → generates UUID → adds to request
   RateLimitFilter runs:
     Checks request count for this IP
     Under limit → passes through
   Route matching:
     /api/** matches core-service route
     Forwards to http://localhost:8082/api/projects
     With added header: X-Correlation-ID: uuid-abc-123

3. Core Service receives the request
   BearerTokenAuthenticationFilter runs:
     cookieTokenResolver reads JWT_TOKEN cookie
     Returns token value: eyJhbGciOiJSUzI1NiJ9...
   NimbusJwtDecoder validates the token:
     Fetches JWKS from Keycloak (cached after first fetch)
     Verifies RS256 signature
     Checks exp claim — not expired
     Checks iss claim — matches configured issuer
     Token is valid
   JwtConverter.convert(jwt) runs:
     Extracts userId claim from JWT
     UserSyncFilter has already ensured user exists in DB
     Queries: AppUser → ProjectMember → Role → Permission
     Collects all unique permissions across all project memberships
     Returns JwtAuthenticationToken with authority list
   SecurityContextHolder populated with:
     Principal: Jwt object
     Authorities: [VIEW_PROJECTS, CREATE_ISSUE, UPDATE_ISSUE, ...]

4. Request reaches ProjectController.getUserProjects()
   @PreAuthorize("hasAuthority('VIEW_PROJECTS')") evaluated
   VIEW_PROJECTS is in authority list → passes
   projectService.getUserProjects(userId) called
   JPA query: SELECT projects WHERE userId is a member
   Returns List<Project>
   Mapped to List<ProjectResponse>
   Wrapped in ApiResponse<List<ProjectResponse>>

5. Response travels back:
   Core Service → Gateway → Browser
   HTTP 200 with JSON body
```

### Request Flow — Login

```
1. User navigates to http://localhost:3000
   Frontend checks /auth/user/me → 401
   Frontend redirects to http://localhost:8080/auth/login

2. Gateway routes /auth/** to auth-service (port 8081)

3. Auth service receives GET /login
   Spring Security's OAuth2AuthorizationRequestRedirectFilter intercepts
   Generates state parameter (UUID for CSRF protection)
   Stores state in HTTP session
   Redirects browser to:
   http://localhost:8180/realms/devcollab/protocol/openid-connect/auth
   ?client_id=devcollab-auth-service
   &response_type=code
   &scope=openid profile email
   &redirect_uri=http://localhost:8081/auth/login/oauth2/code/keycloak
   &state=CSRF_STATE_VALUE

4. Browser follows redirect to Keycloak
   User enters alice / password123
   Keycloak authenticates the user
   Keycloak redirects to:
   http://localhost:8081/auth/login/oauth2/code/keycloak
   ?code=AUTHORIZATION_CODE
   &state=CSRF_STATE_VALUE

5. Auth service receives the callback
   OAuth2LoginAuthenticationFilter intercepts
   Validates state matches stored state → CSRF check passes
   Makes server-to-server call to Keycloak token endpoint:
   POST http://localhost:8180/realms/devcollab/protocol/openid-connect/token
     grant_type=authorization_code
     code=AUTHORIZATION_CODE
     client_id=devcollab-auth-service
     client_secret=SECRET
   Keycloak returns: access_token, id_token, refresh_token

6. OAuth2SuccessHandler runs
   Extracts access_token from OAuth2AuthorizedClient
   Creates Cookie: JWT_TOKEN=access_token
     HttpOnly: true (JS cannot read)
     Secure: false (local) / true (prod)
     Path: /
     MaxAge: 3600
   response.addCookie(jwtCookie)
   response.sendRedirect(http://localhost:3000/dashboard)

7. Browser stores the HttpOnly cookie
   All subsequent API requests automatically include it
   User lands on dashboard page
```

---

## 3. Technology Stack

### Backend

```
Language:           Java 21
Framework:          Spring Boot 3.3.x
Build Tool:         Maven

Gateway:
  Spring Cloud Gateway 2023.0.x (reactive, WebFlux-based)

Auth Service:
  Spring Security (OAuth2 Client)
  Spring Web (MVC)

Core Service:
  Spring Security (OAuth2 Resource Server)
  Spring Web (MVC)
  Spring Data JPA
  Hibernate
  MySQL Connector/J

Common:
  Lombok (boilerplate reduction)
  SpringDoc OpenAPI 2.x (Swagger UI)
  Spring Boot Actuator (health, metrics)
  Jackson (JSON serialisation)
  Bean Validation (javax.validation)
```

### Infrastructure

```
Identity Provider:  Keycloak 25.0.3 (Docker)
Database:           MySQL 8.0 (Docker)
Containerisation:   Docker + Docker Compose
```

### Frontend

```
Language:           JavaScript (ES2022+)
Framework:          React 18
Build Tool:         Vite
Routing:            React Router DOM v6
HTTP Client:        Axios
UI Components:      Shadcn/ui
Styling:            Tailwind CSS
State Management:   React hooks (useState, useEffect, custom hooks)
```

---

## 4. Repository Structure

```
devcollab/
│
├── docker-compose.yml              Infrastructure definition
│
├── docker/
│   ├── mysql/
│   │   └── init.sql                Creates devcollab_auth and devcollab_core databases
│   └── keycloak/
│       └── create-users.sh         Creates test users via Keycloak Admin API
│
├── keycloak/
│   └── devcollab-realm.json        Exported realm config — auto-imported on startup
│
├── gateway/                        Spring Cloud Gateway service
│   ├── src/main/java/com/devcollab/gateway/
│   │   ├── GatewayApplication.java
│   │   ├── filter/
│   │   │   ├── CorrelationIdFilter.java
│   │   │   └── RateLimitFilter.java
│   │   └── config/
│   │       └── GatewayConfig.java
│   └── src/main/resources/
│       ├── application.yml
│       └── application-local.yml
│
├── auth-service/                   OAuth2 Client service
│   ├── src/main/java/com/devcollab/auth/
│   │   ├── AuthServiceApplication.java
│   │   ├── config/
│   │   │   └── SecurityConfig.java
│   │   ├── controller/
│   │   │   ├── AuthController.java
│   │   │   └── UserController.java
│   │   ├── service/
│   │   │   └── UserService.java
│   │   ├── dto/
│   │   │   └── UserDto.java
│   │   └── handler/
│   │       └── OAuth2SuccessHandler.java
│   └── src/main/resources/
│       ├── application.properties
│       ├── application-local.properties
│       └── application-prod.properties
│
├── core-service/                   Main domain service
│   ├── src/main/java/com/devcollab/core/
│   │   ├── CoreServiceApplication.java
│   │   │
│   │   ├── config/
│   │   │   ├── SecurityConfig.java
│   │   │   ├── SecurityConfigLocal.java
│   │   │   ├── JwtConfig.java
│   │   │   └── RestTemplateConfig.java
│   │   │
│   │   ├── security/
│   │   │   ├── JwtConverter.java
│   │   │   ├── ApiKeyFilter.java
│   │   │   ├── ApiKeyProvider.java
│   │   │   └── ApiKeyAuthentication.java
│   │   │
│   │   ├── rbac/
│   │   │   ├── Permission.java
│   │   │   ├── Role.java
│   │   │   ├── RolePermission.java
│   │   │   ├── PermissionRepository.java
│   │   │   ├── RoleRepository.java
│   │   │   └── PermissionBootstrap.java
│   │   │
│   │   ├── user/
│   │   │   ├── AppUser.java
│   │   │   ├── UserRepository.java
│   │   │   ├── UserService.java
│   │   │   ├── UserController.java
│   │   │   └── UserSyncFilter.java
│   │   │
│   │   ├── project/
│   │   │   ├── Project.java
│   │   │   ├── ProjectStatus.java
│   │   │   ├── ProjectRepository.java
│   │   │   ├── ProjectService.java
│   │   │   ├── ProjectController.java
│   │   │   └── dto/
│   │   │       ├── ProjectRequest.java
│   │   │       └── ProjectResponse.java
│   │   │
│   │   ├── issue/
│   │   │   ├── Issue.java
│   │   │   ├── IssueStatus.java
│   │   │   ├── IssuePriority.java
│   │   │   ├── IssueType.java
│   │   │   ├── IssueRepository.java
│   │   │   ├── IssueService.java
│   │   │   ├── IssueController.java
│   │   │   ├── StatusTransitionValidator.java
│   │   │   └── dto/
│   │   │       ├── IssueRequest.java
│   │   │       ├── IssueResponse.java
│   │   │       └── IssueFilterRequest.java
│   │   │
│   │   ├── member/
│   │   │   ├── ProjectMember.java
│   │   │   ├── MemberRepository.java
│   │   │   ├── MemberService.java
│   │   │   └── MemberController.java
│   │   │
│   │   ├── common/
│   │   │   ├── PagedResponse.java
│   │   │   ├── ApiResponse.java
│   │   │   ├── PageableValidator.java
│   │   │   ├── SortStrategy.java
│   │   │   ├── DateSortStrategy.java
│   │   │   ├── PrioritySortStrategy.java
│   │   │   ├── UpdatedSortStrategy.java
│   │   │   ├── DueDateSortStrategy.java
│   │   │   └── SortStrategyFactory.java
│   │   │
│   │   └── exception/
│   │       ├── GlobalExceptionHandler.java
│   │       ├── ResourceNotFoundException.java
│   │       ├── ForbiddenException.java
│   │       ├── ValidationException.java
│   │       └── ErrorResponse.java
│   │
│   └── src/main/resources/
│       ├── application.properties
│       ├── application-local.properties
│       ├── application-prod.properties
│       └── permissions.json
│
└── frontend/                       React application
    ├── public/
    ├── src/
    │   ├── main.jsx
    │   ├── App.jsx
    │   ├── api/
    │   │   └── axiosConfig.js
    │   ├── hooks/
    │   │   ├── useAuth.js
    │   │   ├── useProjects.js
    │   │   └── useIssues.js
    │   ├── pages/
    │   │   ├── LoginPage.jsx
    │   │   ├── DashboardPage.jsx
    │   │   ├── ProjectPage.jsx
    │   │   └── CreateIssuePage.jsx
    │   └── components/
    │       ├── Navbar.jsx
    │       ├── IssueCard.jsx
    │       ├── FilterBar.jsx
    │       └── ProtectedRoute.jsx
    ├── package.json
    └── vite.config.js
```

---

## 5. Infrastructure Setup

### Prerequisites

Docker Desktop installed and running. Java 21 installed. Maven 3.9+ installed. Node.js 20+ installed.

### docker-compose.yml

```yaml
version: '3.8'

services:
  mysql:
    image: mysql:8.0
    container_name: devcollab-mysql
    environment:
      MYSQL_ROOT_PASSWORD: rootpassword
      MYSQL_ROOT_HOST: '%'
    ports:
      - "3306:3306"
    volumes:
      - mysql-data:/var/lib/mysql
      - ./docker/mysql/init.sql:/docker-entrypoint-initdb.d/init.sql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-prootpassword"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    networks:
      - devcollab-network

  keycloak:
    image: quay.io/keycloak/keycloak:25.0.3
    container_name: devcollab-keycloak
    environment:
      KEYCLOAK_ADMIN: admin
      KEYCLOAK_ADMIN_PASSWORD: admin
    ports:
      - "8180:8080"
    volumes:
      - ./keycloak/devcollab-realm.json:/opt/keycloak/data/import/devcollab-realm.json
    command: start-dev --import-realm
    depends_on:
      mysql:
        condition: service_healthy
    networks:
      - devcollab-network

  keycloak-setup:
    image: curlimages/curl:latest
    container_name: devcollab-keycloak-setup
    volumes:
      - ./docker/keycloak/create-users.sh:/create-users.sh
    command: sh /create-users.sh
    depends_on:
      keycloak:
        condition: service_started
    networks:
      - devcollab-network
    restart: on-failure

volumes:
  mysql-data:

networks:
  devcollab-network:
    driver: bridge
```

### MySQL Init Script — docker/mysql/init.sql

```sql
CREATE DATABASE IF NOT EXISTS devcollab_auth
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE DATABASE IF NOT EXISTS devcollab_core
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'auth_user'@'%' IDENTIFIED BY 'auth_pass';
CREATE USER IF NOT EXISTS 'core_user'@'%' IDENTIFIED BY 'core_pass';

GRANT ALL PRIVILEGES ON devcollab_auth.* TO 'auth_user'@'%';
GRANT ALL PRIVILEGES ON devcollab_core.* TO 'core_user'@'%';

FLUSH PRIVILEGES;
```

### Keycloak Realm

The `keycloak/devcollab-realm.json` file is exported from Keycloak after manual configuration and committed to the repository. It contains the complete realm configuration including clients, scopes, and mappers. It does not reliably contain user credentials due to password hash portability issues, which is why test users are created separately via the `create-users.sh` script.

The realm configuration includes:

```
Realm name: devcollab

Clients:
  devcollab-auth-service
    - Confidential client
    - Authorization Code flow enabled
    - Direct Access Grants enabled (local only)
    - Redirect URI: http://localhost:8081/auth/login/oauth2/code/keycloak
    - Scope: devcollab-user-info (custom)

  devcollab-core-service
    - Confidential client
    - No flows needed (resource server only)

Client Scopes:
  devcollab-user-info
    - Mapper: userId → maps Keycloak internal user id to userId claim
    - Added to devcollab-auth-service as default scope

Token Settings:
  Access token lifespan: 300 seconds (5 minutes)
  Refresh token lifespan: 1800 seconds (30 minutes)
```

---

## 6. Backend Services

### 6.1 Gateway Service

#### Purpose

Single entry point for all external traffic. Routes requests to downstream services by URL prefix. Injects correlation IDs. Enforces rate limiting. Handles CORS.

#### Port

8080

#### Routes

```
/auth/**  → http://localhost:8081
/api/**   → http://localhost:8082
```

#### Filters

**CorrelationIdFilter (GlobalFilter, Order = -1)**

Runs before any other filter on every request. Checks for `X-Correlation-ID` header. If absent, generates a UUID and adds it. Ensures the header flows downstream. This ID appears in logs of every service that handles the request, enabling end-to-end request tracing.

**RateLimitFilter (GlobalFilter, Order = 0)**

Tracks request counts per client IP address using a `ConcurrentHashMap<String, AtomicInteger>`. A scheduled task resets all counts every 60 seconds. If a client exceeds 100 requests per minute, the filter returns HTTP 429 Too Many Requests with a `Retry-After: 60` header. The request does not reach the downstream service.

This is an in-memory implementation suitable for a single gateway instance. For a multi-instance gateway deployment, this would be replaced with Redis-backed rate limiting using Spring Cloud Gateway's built-in `RequestRateLimiter` filter.

#### CORS Configuration

CORS is configured at the gateway level and applies to all routes. Downstream services do not configure CORS independently. This centralises CORS management and avoids conflicting configurations.

```
Local profile:
  allowedOrigins: http://localhost:3000
  allowedMethods: GET, POST, PUT, DELETE, OPTIONS
  allowedHeaders: *
  allowCredentials: true
  maxAge: 3600

Production profile:
  allowedOrigins: ${ALLOWED_ORIGIN} (environment variable)
  Same methods and headers
```

The `allowCredentials: true` setting is required because the JWT lives in a cookie. The browser will not send cookies on cross-origin requests unless the server explicitly allows credentials. Combined with `allowedOrigins` being a specific origin (not a wildcard), this is a valid and secure CORS configuration.

#### Actuator

Only `health` and `info` endpoints are exposed. Default access is denied. The health endpoint returns UP or DOWN with no internal details.

---

### 6.2 Auth Service

#### Purpose

Handles user authentication via Keycloak using the OAuth2 Authorization Code flow. Sets the JWT access token as an HttpOnly cookie after successful login. Provides the current user's identity. Handles logout including Keycloak session termination.

#### Port

8081

#### Context Path

`/auth` — all endpoints are prefixed with `/auth`

#### Security Mode

OAuth2 Client (`.oauth2Login()`). This service is NOT a resource server. It does not validate incoming JWTs. It initiates flows and receives tokens.

The service maintains HTTP sessions during the OAuth2 flow to store the CSRF state parameter. Sessions are not used for authentication state — after the cookie is set, the session is no longer needed for subsequent requests to other services.

#### Key Design Decisions

**Why a separate auth service?**

The auth service uses `oauth2Login()` which requires session management during the flow. The core service uses `oauth2ResourceServer()` which is completely stateless. These two modes cannot cleanly coexist in the same application. A request to the resource server must be stateless — it validates the JWT and is done. A login request requires the server to maintain state (the CSRF state parameter) across two HTTP requests (the initial redirect and the callback). Mixing these concerns in one service creates confusion about which endpoints are stateful and which are not.

**Why extract the token and set a cookie?**

The frontend is a React SPA running on a different port (3000) than the API (8080). If the token were returned in the response body, the frontend JavaScript would need to store it somewhere — localStorage (XSS-vulnerable) or memory (lost on page refresh). An HttpOnly cookie is neither readable by JavaScript nor lost on refresh. The cookie is automatically sent by the browser on every request to the same domain, making API calls from the frontend completely transparent from an auth perspective.

**Why POST for logout?**

GET requests can be triggered by any page via image tags or links without the user's knowledge. POST requests require deliberate action from JavaScript. Using POST for logout protects against CSRF-based forced logout attacks.

#### Endpoints

```
GET  /auth/login
     Purpose: Entry point for the login flow
     Security: Public (Spring Security redirects to Keycloak before this code runs)
     Behaviour: For authenticated users, redirects to frontend dashboard
                For unauthenticated users, Spring Security redirects to Keycloak
                before the controller method executes

GET  /auth/login/oauth2/code/keycloak
     Purpose: OAuth2 callback URL
     Security: Handled entirely by Spring Security
     Behaviour: Spring validates state, exchanges code for tokens,
                calls OAuth2SuccessHandler
     Note: This endpoint is managed by Spring. Do not add a controller method for it.

POST /auth/logout
     Purpose: Log out the current user
     Security: Authenticated
     Behaviour: Invalidates HTTP session
                Clears JWT_TOKEN cookie (sets MaxAge=0)
                Redirects to Keycloak end-session endpoint
                Keycloak redirects back to frontend after session termination

GET  /auth/user/me
     Purpose: Returns current user's identity
     Security: Authenticated
     Response: { userId, email, firstName, lastName }
```

#### OAuth2SuccessHandler

Called by Spring Security after the OAuth2 flow completes. Extracts the access token from `OAuth2AuthorizedClient`, creates an HttpOnly cookie, and redirects to the frontend dashboard. This is the bridge between the OAuth2 world (tokens managed by Spring) and the cookie world (tokens managed by the browser).

---

### 6.3 Core Service

#### Purpose

The main domain service. Handles all business logic — projects, issues, members, and RBAC. Validates JWTs independently. Resolves user permissions dynamically from the database on every request.

#### Port

8082

#### Context Path

`/api` — all endpoints are prefixed with `/api`

#### Database

`devcollab_core` schema in MySQL.

#### Security Mode

OAuth2 Resource Server (`.oauth2ResourceServer().jwt()`). Completely stateless. No sessions. No login flows. Validates the JWT on every request.

#### Security Layer — How It Works

**Token Extraction**

The `cookieTokenResolver` bean reads the JWT from the `JWT_TOKEN` cookie. If the cookie is absent, it falls back to the standard `Authorization: Bearer <token>` header. This dual approach means browser users (cookie) and programmatic clients like Postman or CLI tools (Authorization header) both work without separate endpoints.

**JWT Validation**

`NimbusJwtDecoder` validates the token using Keycloak's JWKS endpoint. On first request, it fetches the public keys from `http://localhost:8180/realms/devcollab/protocol/openid-connect/certs` and caches them. On each request it verifies the RS256 signature, checks the `exp` claim, and checks the `iss` claim. If any check fails, the request is rejected with 401.

**Permission Resolution (JwtConverter)**

This is the most important class in the security layer. After JWT validation, `JwtConverter.convert(jwt)` is called. It extracts the `userId` claim from the validated JWT, queries the database for all unique permissions across all of the user's project memberships, and returns a `JwtAuthenticationToken` with that permission list.

The critical design decision here is that permissions are fetched from the database on every request rather than embedded in the JWT. This means permission changes take effect on the next request — there is no stale permission window. The trade-off is one database query per authenticated request. For an internal tool at this scale, this is the right trade-off.

**Coarse vs Fine-Grained Permission Checking**

The system uses a two-layer permission check:

Layer 1 — `@PreAuthorize` on the controller method. This is a coarse check: "does this user have this permission in any project?" It prevents users with no relevant permissions from reaching the service layer at all.

Layer 2 — Service layer check. This is the fine-grained check: "does this user have this permission specifically on this project?" The `@PreAuthorize` check passes if the user is DEVELOPER on any project and hits `CREATE_ISSUE`. The service layer check verifies they are specifically a member of the project they are trying to create an issue in. Both checks must pass.

**API Key Authentication**

The `ApiKeyFilter` (`OncePerRequestFilter`) checks for an `X-API-KEY` header on every request. If present, it passes the key to `ApiKeyProvider` which validates it against the configured value (`devcollab.api.key` property). If valid, an `ApiKeyAuthentication` object is placed in the `SecurityContextHolder`. If the API key is invalid, the filter returns 401 immediately without calling the next filter.

If no API key header is present, the filter calls `filterChain.doFilter()` without setting any authentication — the JWT filter will handle authentication instead. This allows both JWT and API key to coexist without conflict.

**UserSyncFilter**

When a user logs in for the first time, they exist in Keycloak but not in the `app_users` table. The `UserSyncFilter` runs after `BearerTokenAuthenticationFilter` on every authenticated request. It reads the `userId` from the JWT, checks if a row exists in `app_users`, and creates one if not. This is just-in-time user provisioning. The user record in the DB stores only the information needed for domain queries — the Keycloak ID, email, and name. Keycloak remains the authoritative source of identity.

#### RBAC Model

```
Permission
  code: String (PK)   e.g. VIEW_ISSUES
  description: String

Role
  name: String (PK)   e.g. DEVELOPER
  permissions: ManyToMany → Permission

AppUser
  id: String (PK)     Keycloak userId claim
  email: String
  firstName: String
  lastName: String

ProjectMember
  id: Long
  user: ManyToOne → AppUser
  project: ManyToOne → Project
  role: ManyToOne → Role

Query for JwtConverter:
  SELECT DISTINCT p.code
  FROM permissions p
  JOIN role_permissions rp ON p.code = rp.permission_code
  JOIN roles r ON rp.role_name = r.name
  JOIN project_members pm ON r.name = pm.role_name
  WHERE pm.user_id = :userId
```

#### Default Roles and Permissions

```
Permissions:
  VIEW_PROJECTS    View projects user is a member of
  CREATE_PROJECT   Create a new project
  UPDATE_PROJECT   Update project name and description
  DELETE_PROJECT   Permanently delete a project
  ARCHIVE_PROJECT  Archive a project (soft disable)
  VIEW_ISSUES      View issues in a project
  CREATE_ISSUE     Create a new issue
  UPDATE_ISSUE     Update issue fields
  DELETE_ISSUE     Delete an issue
  MANAGE_MEMBERS   Add, remove, and change roles of project members
  VIEW_MEMBERS     View the member list of a project

Roles:
  OWNER     All 11 permissions
  ADMIN     All except DELETE_PROJECT
  DEVELOPER VIEW_PROJECTS, VIEW_ISSUES, CREATE_ISSUE, UPDATE_ISSUE, VIEW_MEMBERS
  VIEWER    VIEW_PROJECTS, VIEW_ISSUES, VIEW_MEMBERS
```

Permissions are seeded from `permissions.json` on startup by `PermissionBootstrap` using a `@PostConstruct` method. The bootstrap diffs the JSON against the database — it inserts new permissions and removes obsolete ones. This means adding a permission requires only a JSON edit and a deployment restart, with no manual SQL.

Roles and their permission mappings are seeded by `RoleBootstrap` using the same pattern.

#### Project Domain

A project represents a client engagement. It has an owner (the user who created it), a name, a description, and a status (ACTIVE or ARCHIVED). Membership is managed through `ProjectMember` records which associate a user, a project, and a role.

A critical security rule: if a user is not a member of a project, the project does not exist from their perspective. `getProjectById` throws `ResourceNotFoundException` (404) rather than `ForbiddenException` (403) for non-members. This prevents information leakage — a user should not be able to determine that a project exists just because they cannot access it.

Deleting a project cascades to delete all its members and issues.
Archiving a project sets status to ARCHIVED but preserves all data.
There must always be at least one OWNER per project. Removing the last OWNER is rejected with a 400 error.

#### Issue Domain

Issues are the core entity. Each issue belongs to one project. The `reporterId` is set automatically from the authenticated user's JWT on creation and cannot be changed afterward. The `assigneeId` can be set to any project member or left null.

**Status Transitions**

The `StatusTransitionValidator` implements the Chain of Responsibility pattern. Each validator in the chain checks one rule. The valid transitions are:

```
OPEN        → IN_PROGRESS, CLOSED
IN_PROGRESS → IN_REVIEW, OPEN, CLOSED
IN_REVIEW   → IN_PROGRESS, DONE, CLOSED
DONE        → CLOSED
CLOSED      → OPEN
```

Any other transition results in a `ValidationException` which the `GlobalExceptionHandler` converts to HTTP 400 with a descriptive message.

**Filtering and Pagination**

Issue filtering uses JPA's `Specification` API. The `IssueSpecificationBuilder` implements the Builder pattern — it accepts an `IssueFilterRequest`, adds one `Specification` per non-null filter field, combines them with `.and()`, and returns the composed `Specification<Issue>`.

Individual specifications are static methods in `IssueSpecification`:

- `hasStatuses(List<IssueStatus>)` — generates a JPA `IN` clause
- `hasPriorities(List<IssuePriority>)` — generates a JPA `IN` clause
- `hasTypes(List<IssueType>)` — generates a JPA `IN` clause
- `hasAssignee(String)` — equality check
- `hasReporter(String)` — equality check
- `dueBetween(LocalDate, LocalDate)` — range check on dueDate
- `titleContains(String)` — case-insensitive LIKE query
- `belongsToProject(UUID)` — equality check on project ID

Sorting uses the Strategy pattern. `SortStrategy` is an interface with one method: `Sort buildSort()`. Four implementations exist: `DateSortStrategy`, `PrioritySortStrategy`, `UpdatedSortStrategy`, `DueDateSortStrategy`. `SortStrategyFactory` accepts a string parameter and returns the appropriate implementation.

`PageableValidator` validates and sanitises the incoming pageable object: maximum page size of 50, sort fields validated against a whitelist to prevent injection, default to page 0 and size 20 if not specified.

All list responses are wrapped in `PagedResponse<T>`:

```json
{
  "data": [...],
  "page": 0,
  "size": 20,
  "totalElements": 143,
  "totalPages": 8,
  "hasNext": true,
  "hasPrevious": false,
  "appliedFilters": {
    "statuses": ["OPEN", "IN_PROGRESS"],
    "priorities": ["HIGH"]
  }
}
```

#### Exception Handling

`GlobalExceptionHandler` annotated with `@ControllerAdvice` handles all exceptions thrown from any controller or service in the application.

All error responses use a consistent shape:

```json
{
  "status": 400,
  "error": "Validation Failed",
  "message": "Title must not exceed 200 characters",
  "timestamp": "2024-01-15T10:30:00",
  "correlationId": "uuid-from-x-correlation-id-header"
}
```

The `correlationId` is read from the `X-Correlation-ID` request header (injected by the gateway). Every error response is therefore traceable across the service logs.

Exception mappings:

```
ResourceNotFoundException   → 404 Not Found
ForbiddenException          → 403 Forbidden
ValidationException         → 400 Bad Request
MethodArgumentNotValidException → 400 Bad Request (field-level errors)
AccessDeniedException       → 403 Forbidden
AuthenticationException     → 401 Unauthorized
Exception (catch-all)       → 500 Internal Server Error
                               (message hidden, logged internally)
```

---

## 7. Frontend

### Purpose

A minimal React SPA that demonstrates the security model and core domain flows. The frontend is intentionally simple — its purpose is to prove the backend API works end to end in a real browser environment, not to be a production-grade UI.

### Port

3000 (Vite dev server)

### Architecture

The frontend follows a simple three-layer architecture:

```
Pages       — full page components, each corresponds to a route
Components  — reusable UI pieces used by multiple pages
Hooks       — data fetching and state management logic
API         — axios configuration and base HTTP client
```

Pages contain layout and user interaction logic. They use hooks to fetch and mutate data. They use components to render UI. They do not make axios calls directly — that is the hook's job.

Hooks contain all the data fetching logic. They use axios. They manage loading and error state. They expose data and mutation functions to pages. This separation means the same data fetching logic can be reused across multiple pages.

Components are pure UI elements with no data fetching. They receive data as props and emit events via callback props.

### axiosConfig.js

The single most important frontend file from a security perspective.

```javascript
import axios from 'axios';

const api = axios.create({
  baseURL: 'http://localhost:8080',
  withCredentials: true
});

export default api;
```

The `withCredentials: true` setting instructs the browser to include cookies on cross-origin requests. Without this, the `JWT_TOKEN` cookie is never sent to `localhost:8080` from `localhost:3000`, and every request returns 401.

This setting works in conjunction with the gateway's CORS configuration:

- Gateway sets `Access-Control-Allow-Credentials: true`
- Gateway sets `Access-Control-Allow-Origin: http://localhost:3000` (specific, not wildcard)
- Axios sends `withCredentials: true`

All three must be present for credentialed cross-origin requests to work.

### useAuth Hook

Fetches the current user from `GET /auth/user/me`. Returns `{ user, loading, error }`. Called on application mount to determine if the user is logged in.

If the response is 401, the user is not authenticated. `ProtectedRoute` uses this hook to redirect unauthenticated users to the login page.

The hook does not handle the redirect itself — it only provides the authentication state. Redirect logic lives in `ProtectedRoute`. This separation follows the single responsibility principle.

### useProjects Hook

Fetches the current user's projects from `GET /api/projects`. Returns `{ projects, loading, error, refetch }`. The `refetch` function allows a page to manually trigger a re-fetch after a mutation (e.g., after creating a new project).

### useIssues Hook

Fetches issues for a specific project with optional filter parameters. Accepts a `projectId` and a `filters` object. Builds query parameters from the filters object and appends them to the request URL. Returns `{ issues, pagination, loading, error, refetch }`.

When `filters` changes (user changes a dropdown), the hook re-fetches automatically via a `useEffect` dependency on the filters object.

### ProtectedRoute Component

A wrapper component that uses `useAuth` to check authentication state. While loading, renders a spinner. If the user is null (401 from `/auth/user/me`), redirects to `/login`. If the user is present, renders the child components.

Every page except `LoginPage` is wrapped in `ProtectedRoute`:

```jsx
<Route path="/dashboard" element={
  <ProtectedRoute>
    <DashboardPage />
  </ProtectedRoute>
} />
```

### Pages

**LoginPage**

Renders a single card with a "Login with DevCollab" button. Clicking the button navigates to `http://localhost:8080/auth/login` (full URL navigation, not React Router navigation, because the login flow involves server-side redirects). After Keycloak authentication and the cookie being set, the auth service redirects to `http://localhost:3000/dashboard`.

**DashboardPage**

Uses `useAuth` to get the current user for the navbar. Uses `useProjects` to fetch the project list. Renders a grid of project cards using the Shadcn `Card` component. Each card shows project name, status badge, and a "View Issues" button that navigates to `/projects/:id`.

A "New Project" button opens a Shadcn `Dialog` with a form for project name and description. On submit, calls `POST /api/projects`. On success, calls `refetch()` from `useProjects`.

**ProjectPage**

Receives the `projectId` from React Router params (`useParams()`). Uses `useIssues(projectId, filters)` to fetch the issue list. Renders the `FilterBar` component and maps the issue list to `IssueCard` components.

When the user changes any filter in `FilterBar`, the `filters` state in `ProjectPage` updates. The `useIssues` hook re-fetches because `filters` is in its dependency array. The issue list updates.

Pagination controls (previous page, next page, page size selector) update the `page` and `size` values in the filters object, triggering the same re-fetch.

**CreateIssuePage**

A form page with fields for title (text input), type (select), priority (select), description (textarea), and due date (date input). Uses React's controlled input pattern — each field has a corresponding `useState` value.

On submit, validates client-side (title not empty, title under 200 chars), then calls `POST /api/projects/:id/issues`. On success, navigates back to the project page with `useNavigate()`.

### FilterBar Component

Renders a row of filter controls: status multi-select, priority multi-select, type select, title search input, sort-by select. Each control calls an `onFilterChange` callback prop when its value changes. The parent page (`ProjectPage`) manages the filter state. `FilterBar` is purely presentational — it does not fetch data.

### IssueCard Component

Displays a single issue. Shows title, a priority badge (color-coded using Tailwind: LOW=grey, MEDIUM=blue, HIGH=orange, CRITICAL=red), a status badge, type label, and assignee name if set. Clicking the card could expand to show description or navigate to an issue detail page (not in scope for initial version).

---

## 8. Security Model

### Overview

The security model has four layers. Each layer provides independent protection. Bypassing one layer does not bypass the others.

```
Layer 1: Transport — HTTPS in production (not applicable locally)
Layer 2: Authentication — JWT validation in every service
Layer 3: Coarse authorisation — @PreAuthorize on every controller method
Layer 4: Fine-grained authorisation — membership check in service layer
```

### Token Flow

```
Keycloak issues JWT access token
  ↓
Auth service extracts token, sets as HttpOnly cookie
  ↓
Browser automatically sends cookie on every request
  ↓
Gateway forwards request to downstream service
  ↓
Core service reads cookie, validates JWT signature via JWKS
  ↓
JwtConverter queries DB for user's permissions
  ↓
SecurityContextHolder populated with user identity and authorities
  ↓
@PreAuthorize evaluates authority list
  ↓
Service layer verifies project membership
  ↓
Request processed
```

### Cookie Security Properties

```
Name:     JWT_TOKEN
HttpOnly: true — JavaScript cannot read this cookie
                 XSS attacks cannot steal the token
Secure:   true (prod) / false (local)
          In production: sent only over HTTPS
Path:     / — sent with all requests to the domain
MaxAge:   3600 — expires after 1 hour, matching token TTL
SameSite: Not explicitly set (defaults to Lax in modern browsers)
          Lax: Cookie not sent on cross-site POST/PUT/DELETE
          Protects against CSRF for mutation operations
```

### Permission Evaluation Sequence

```
Request arrives with JWT cookie
  ↓
Is JWT valid? (signature, expiry, issuer)
  No → 401 Unauthorized
  Yes → continue
  ↓
Extract userId from JWT
  ↓
Does user exist in app_users? (UserSyncFilter)
  No → create user record (just-in-time provisioning)
  Yes → continue
  ↓
Query all permissions for this user across all project memberships
  ↓
Populate SecurityContextHolder with authority list
  ↓
@PreAuthorize("hasAuthority('X')") evaluated
  Fails → 403 Forbidden
  Passes → continue
  ↓
Service layer: is user a member of THIS specific project?
  No → 404 Not Found (not 403 — do not reveal project existence)
  Yes → does their role in THIS project permit this action?
    No → 403 Forbidden
    Yes → process request
```

### Why 404 Not 403 for Non-Members

Returning 403 for a project the user is not a member of reveals that the project exists. If an attacker knows a project ID (e.g., from guessing UUIDs or finding one in logs), 403 tells them "this project exists, you just can't access it." 404 tells them nothing. This is called security through obscurity at the access control layer and is a standard pattern for multi-tenant systems.

### API Key Security

API keys are used for programmatic access (CLI tools, scripts, CI pipelines). The key is configured via `devcollab.api.key` property, injected via environment variable in production.

```
X-API-KEY: devcollab-local-key

Validation uses constant-time comparison (MessageDigest.isEqual) to prevent
timing side-channel attacks. A regular string equals() comparison is faster
when it fails early (first character mismatch), which can leak key prefix
information through response time measurement.
```

API key authentication grants the same access as a fully-authenticated JWT user with all permissions. In a production scenario, API keys would be scoped to specific permissions. For this project, API keys represent trusted service clients.

---

## 9. API Reference

All endpoints require authentication (JWT cookie or API key) unless marked as public.

All responses follow the standard envelope:

```json
{
  "data": { ... },
  "message": "Success",
  "timestamp": "2024-01-15T10:30:00"
}
```

All error responses:

```json
{
  "status": 400,
  "error": "Bad Request",
  "message": "Descriptive message",
  "timestamp": "2024-01-15T10:30:00",
  "correlationId": "uuid"
}
```

### Auth Service Endpoints

```
GET  /auth/login
     Public
     Redirects to Keycloak login page for unauthenticated users
     Redirects to frontend dashboard for authenticated users

GET  /auth/login/oauth2/code/keycloak
     Public (managed by Spring Security)
     Handles OAuth2 callback from Keycloak
     Sets JWT_TOKEN cookie on success

POST /auth/logout
     Authenticated
     Body: none
     Clears JWT_TOKEN cookie
     Redirects to Keycloak end-session endpoint

GET  /auth/user/me
     Authenticated
     Returns: { userId, email, firstName, lastName }
```

### Core Service — Projects

```
GET  /api/projects
     Permission: VIEW_PROJECTS
     Returns: PagedResponse<ProjectResponse>
     Query params: page, size, sort

POST /api/projects
     Permission: CREATE_PROJECT
     Body: { name, description }
     Returns: ProjectResponse
     Side effect: Creates OWNER membership for the requesting user

GET  /api/projects/{id}
     Permission: VIEW_PROJECTS
     Returns: ProjectResponse
     Note: 404 if user is not a member (not 403)

PUT  /api/projects/{id}
     Permission: UPDATE_PROJECT
     Membership check: must be OWNER or ADMIN
     Body: { name, description }
     Returns: ProjectResponse

DELETE /api/projects/{id}
     Permission: DELETE_PROJECT
     Membership check: must be OWNER
     Returns: 204 No Content
     Cascades: deletes all members and issues

PUT  /api/projects/{id}/archive
     Permission: ARCHIVE_PROJECT
     Membership check: must be OWNER or ADMIN
     Returns: ProjectResponse with status=ARCHIVED
```

### Core Service — Members

```
GET  /api/projects/{id}/members
     Permission: VIEW_MEMBERS
     Membership check: must be a member
     Returns: List<MemberResponse>

POST /api/projects/{id}/members
     Permission: MANAGE_MEMBERS
     Membership check: must be OWNER or ADMIN
     Body: { userId, role }
     Returns: MemberResponse
     Validation: role must be OWNER, ADMIN, DEVELOPER, or VIEWER

PUT  /api/projects/{id}/members/{userId}
     Permission: MANAGE_MEMBERS
     Membership check: must be OWNER or ADMIN
     Body: { role }
     Returns: MemberResponse
     Validation: cannot change own role, cannot demote last OWNER

DELETE /api/projects/{id}/members/{userId}
     Permission: MANAGE_MEMBERS
     Membership check: must be OWNER or ADMIN
     Returns: 204 No Content
     Validation: cannot remove last OWNER
```

### Core Service — Issues

```
GET  /api/projects/{id}/issues
     Permission: VIEW_ISSUES
     Membership check: must be a member
     Query params:
       statuses=OPEN,IN_PROGRESS   (comma-separated enum values)
       priorities=HIGH,CRITICAL
       types=BUG,FEATURE
       assigneeId=userId
       reporterId=userId
       dueDateFrom=2024-01-01      (ISO date format)
       dueDateTo=2024-12-31
       titleSearch=auth            (case-insensitive partial match)
       page=0                      (zero-indexed)
       size=20                     (max 50)
       sort=created                (created, updated, priority, due)
       direction=DESC              (ASC or DESC)
     Returns: PagedResponse<IssueResponse>

POST /api/projects/{id}/issues
     Permission: CREATE_ISSUE
     Membership check: must be a member
     Body: { title, description, type, priority, assigneeId, dueDate }
     Returns: IssueResponse
     Auto-set: reporterId from JWT, status=OPEN, createdAt, updatedAt

GET  /api/projects/{projectId}/issues/{issueId}
     Permission: VIEW_ISSUES
     Membership check: must be a member
     Returns: IssueResponse

PUT  /api/projects/{projectId}/issues/{issueId}
     Permission: UPDATE_ISSUE
     Membership check: must be a member
     Body: { title, description, type, priority, assigneeId, dueDate }
     Returns: IssueResponse
     Note: status is not updated via this endpoint

PUT  /api/projects/{projectId}/issues/{issueId}/status
     Permission: UPDATE_ISSUE
     Membership check: must be a member
     Body: { status }
     Returns: IssueResponse
     Validation: StatusTransitionValidator enforces valid transitions

DELETE /api/projects/{projectId}/issues/{issueId}
     Permission: DELETE_ISSUE
     Membership check: must be OWNER or ADMIN
     Returns: 204 No Content
```

---

## 10. Database Schema

### devcollab_auth

This schema is managed by the auth service. Currently minimal — the auth service may not need persistent storage in the initial implementation since user identity comes entirely from Keycloak.

### devcollab_core

```sql
CREATE TABLE permissions (
  code        VARCHAR(50)  PRIMARY KEY,
  description VARCHAR(200) NOT NULL
);

CREATE TABLE roles (
  name        VARCHAR(50)  PRIMARY KEY,
  description VARCHAR(200) NOT NULL
);

CREATE TABLE role_permissions (
  role_name       VARCHAR(50) NOT NULL,
  permission_code VARCHAR(50) NOT NULL,
  PRIMARY KEY (role_name, permission_code),
  FOREIGN KEY (role_name) REFERENCES roles(name) ON DELETE CASCADE,
  FOREIGN KEY (permission_code) REFERENCES permissions(code) ON DELETE CASCADE
);

CREATE TABLE app_users (
  id          VARCHAR(50)  PRIMARY KEY,  -- Keycloak user ID
  email       VARCHAR(200) NOT NULL UNIQUE,
  first_name  VARCHAR(100) NOT NULL,
  last_name   VARCHAR(100) NOT NULL,
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE projects (
  id          VARCHAR(36)  PRIMARY KEY,  -- UUID
  name        VARCHAR(100) NOT NULL,
  description VARCHAR(500),
  status      VARCHAR(20)  NOT NULL DEFAULT 'ACTIVE',
  owner_id    VARCHAR(50)  NOT NULL,
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  FOREIGN KEY (owner_id) REFERENCES app_users(id)
);

CREATE TABLE project_members (
  id          BIGINT       PRIMARY KEY AUTO_INCREMENT,
  project_id  VARCHAR(36)  NOT NULL,
  user_id     VARCHAR(50)  NOT NULL,
  role_name   VARCHAR(50)  NOT NULL,
  joined_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uq_project_member (project_id, user_id),
  FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE,
  FOREIGN KEY (user_id)    REFERENCES app_users(id) ON DELETE CASCADE,
  FOREIGN KEY (role_name)  REFERENCES roles(name)
);

CREATE TABLE issues (
  id          VARCHAR(36)  PRIMARY KEY,  -- UUID
  title       VARCHAR(200) NOT NULL,
  description TEXT,
  type        VARCHAR(20)  NOT NULL,
  status      VARCHAR(20)  NOT NULL DEFAULT 'OPEN',
  priority    VARCHAR(20)  NOT NULL DEFAULT 'MEDIUM',
  project_id  VARCHAR(36)  NOT NULL,
  assignee_id VARCHAR(50),
  reporter_id VARCHAR(50)  NOT NULL,
  due_date    DATE,
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  FOREIGN KEY (project_id)  REFERENCES projects(id) ON DELETE CASCADE,
  FOREIGN KEY (assignee_id) REFERENCES app_users(id) ON SET NULL,
  FOREIGN KEY (reporter_id) REFERENCES app_users(id)
);

-- Index for common filter queries
CREATE INDEX idx_issues_project_status    ON issues(project_id, status);
CREATE INDEX idx_issues_project_priority  ON issues(project_id, priority);
CREATE INDEX idx_issues_assignee          ON issues(assignee_id);
CREATE INDEX idx_issues_due_date          ON issues(due_date);
```

---

## 11. Running Locally

### First-Time Setup

```bash
# Clone the repository
git clone https://github.com/yourname/devcollab.git
cd devcollab

# Start infrastructure
docker-compose up -d

# Wait for Keycloak to be ready (watch logs)
docker-compose logs -f keycloak
# Wait until you see: Keycloak 25.0.3 on JVM

# Verify MySQL databases exist
docker exec -it devcollab-mysql mysql -u root -prootpassword -e "SHOW DATABASES;"
# Should show devcollab_auth and devcollab_core

# Verify Keycloak realm was imported
# Open browser: http://localhost:8180
# Login: admin / admin
# Switch to devcollab realm
# Check Clients — should see devcollab-auth-service and devcollab-core-service
```

### Running the Services

Open three terminal windows or use IntelliJ's run configurations.

**Terminal 1 — Gateway:**

```bash
cd gateway
mvn spring-boot:run -Dspring-boot.run.profiles=local
```

**Terminal 2 — Auth Service:**

```bash
cd auth-service
mvn spring-boot:run -Dspring-boot.run.profiles=local
```

**Terminal 3 — Core Service:**

```bash
cd core-service
mvn spring-boot:run -Dspring-boot.run.profiles=local
```

**Terminal 4 — Frontend:**

```bash
cd frontend
npm run dev
```

### Verifying the Setup

```
Gateway health:    GET http://localhost:8080/actuator/health → {"status":"UP"}
Auth service:      GET http://localhost:8081/actuator/health → {"status":"UP"}
Core service:      GET http://localhost:8082/actuator/health → {"status":"UP"}
Keycloak:          http://localhost:8180/realms/devcollab/.well-known/openid-configuration
Frontend:          http://localhost:3000
Swagger (core):    http://localhost:8082/swagger-ui.html (local profile only)
```

### Test User Credentials

```
Alice:
  Username: alice
  Password: password123
  Intended role: Project Owner

Bob:
  Username: bob
  Password: password123
  Intended role: Developer
```

### Complete Reset

```bash
# Destroys all containers and volumes — fresh start
docker-compose down -v
docker-compose up -d
```

After a reset the databases are empty and the Keycloak realm is re-imported from the JSON file. Test users are re-created by the `keycloak-setup` container.

---

## 12. Contributing Guidelines

### Before You Start

Read the architecture section completely. Understand the request flow. Understand the security model. Every contribution must be consistent with the two-layer permission model (coarse `@PreAuthorize` + fine service layer check).

### Adding a New Permission

Add the permission code and description to `core-service/src/main/resources/permissions.json`. The `PermissionBootstrap` will seed it on next startup. Add `@PreAuthorize("hasAuthority('YOUR_PERMISSION')")` to the relevant controller method. Add the permission to the appropriate role mappings in `RoleBootstrap`.

### Adding a New Endpoint

Every endpoint must have: `@PreAuthorize` with the relevant permission, input validation with `@Valid` on the request body, a membership check in the service layer for project-scoped resources, and a Swagger `@Operation` annotation.

Follow the response envelope pattern. Return `ApiResponse<T>` for single objects and `PagedResponse<T>` for lists.

### Adding a New Service

If a new Spring Boot service is needed: add it to `docker-compose.yml` if it needs its own infrastructure, add a route in the gateway's `application-local.yml`, configure it as an OAuth2 Resource Server pointing to the same Keycloak JWKS endpoint, implement `cookieTokenResolver` and `JwtConverter` following the core service pattern. Do not share databases between services.

### Code Style

No business logic in controllers. Controllers parse requests, call services, return responses. Services contain all business rules. Repositories contain only data access. Custom queries go in repository interfaces as `@Query` methods. Complex query logic that cannot be expressed as a `@Query` uses a custom repository implementation.

Exception handling is centralised in `GlobalExceptionHandler`. Do not catch and swallow exceptions in controllers or services. Throw the appropriate domain exception and let the handler translate it to HTTP.

All magic strings — permission codes, role names, cookie names, header names — are constants. Define them in a `Constants` class or as static final fields in the relevant class. Do not repeat string literals.
