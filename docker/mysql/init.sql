CREATE DATABASE IF NOT EXISTS devcollab_auth
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE DATABASE IF NOT EXISTS devcollab_core
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

-- Create a dedicated user for each database
-- This is more secure than using root for everything
CREATE USER IF NOT EXISTS 'auth_user'@'%' IDENTIFIED BY 'auth_pass';
CREATE USER IF NOT EXISTS 'core_user'@'%' IDENTIFIED BY 'core_pass';

-- Grant each user access only to their own database
GRANT ALL PRIVILEGES ON devcollab_auth.* TO 'auth_user'@'%';
GRANT ALL PRIVILEGES ON devcollab_core.* TO 'core_user'@'%';

FLUSH PRIVILEGES;