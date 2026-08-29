# Laravel Project Setup Script

A safe, interactive Bash script for creating and configuring **Laravel projects on Debian and Ubuntu**.

The script automates the repetitive server-side configuration normally required when starting a new Laravel project, including PHP-FPM, Composer, Node.js, npm, Git, Apache, MySQL/MariaDB, permissions, ACLs, local domains, and Laravel environment configuration.

It supports three project workflows:

1. **Normal Laravel** — creates the Laravel application with Composer.
2. **Vemto** — prepares an empty directory for Vemto to generate the application.
3. **GitHub** — clones an existing Laravel project from GitHub and configures it.

---

## Features

### System detection

* Detects Debian or Ubuntu automatically.
* Verifies Apache 2.4+.
* Detects installed PHP-FPM versions dynamically.
* Detects the highest available PHP-FPM version.
* Allows the user to select the PHP version.
* Installs PHP automatically if no usable PHP-FPM version is available.
* Verifies the selected PHP-FPM service and socket.

### Laravel compatibility

The script does **not** rely on an unnecessarily rigid PHP/Laravel compatibility matrix.

Instead, it:

* Detects the selected PHP version.
* Presents appropriate Laravel choices.
* Lets the user choose the Laravel version.
* Uses Composer to create the selected Laravel version.
* Executes Composer explicitly through the selected PHP binary.

Example:

```text
INSTALLED PHP-FPM VERSIONS

  1) PHP 8.1
  2) PHP 8.3
  3) PHP 8.4

Highest installed PHP-FPM version: PHP 8.4

Select PHP version [default: 3 - PHP 8.4]:
```

The selected PHP interpreter is then used consistently for Laravel and Artisan commands.

---

## Project Types

### 1. Normal Laravel

Composer creates a new Laravel application.

```text
Composer
    ↓
Laravel application
    ↓
.env
    ↓
Application key
    ↓
Apache
    ↓
MySQL
```

The script creates the project using:

```bash
composer create-project laravel/laravel
```

with Composer executed through the selected PHP version.

---

### 2. Vemto

Vemto projects are handled differently.

The script creates and configures the project directory but does **not** attempt to generate Laravel files itself.

This is important because a new Vemto directory can legitimately be empty.

The script therefore does not assume that these directories already exist:

```text
storage/
bootstrap/cache/
public/
```

They are created when necessary.

Afterward, Vemto can generate the Laravel application inside the directory.

---

### 3. GitHub

The script can also clone an existing Laravel project.

Example:

```text
Project type:

  1) Normal Laravel
  2) Vemto
  3) Import from GitHub
```

The GitHub URL is validated before cloning.

The script also uses:

```bash
git ls-remote
```

to verify that the repository is reachable before proceeding.

This helps detect:

* Invalid repository URLs
* Non-existent repositories
* Authentication problems
* Missing SSH credentials for private repositories

Both common GitHub URL formats can be supported:

```text
https://github.com/user/project
https://github.com/user/project.git
```

and:

```text
git@github.com:user/project.git
```

---

# Requirements

The script is designed for:

* Debian
* Ubuntu
* systemd
* Apache 2.4+
* Bash 4+
* MySQL or MariaDB

The user running the script must have `sudo` privileges.

The script can install missing packages when necessary.

---

# What the Script Configures

A typical project will receive:

```text
Project
├── app/
├── bootstrap/
│   └── cache/
├── config/
├── database/
├── public/
├── resources/
├── routes/
├── storage/
├── .env
└── artisan
```

Apache is configured with a dedicated VirtualHost.

For example:

```text
myproject.test
```

The corresponding project URL becomes:

```text
http://myproject.test
```

The script automatically updates:

```text
/etc/hosts
```

with:

```text
127.0.0.1 myproject.test
```

---

# Dynamic Project Directory

The script does not contain a hard-coded username.

Instead, it detects the user who launched the script with `sudo`.

For example, if the current user is:

```text
john
```

the script can offer:

```text
/var/www
/home/john/www
/srv/www
```

If the selected directory does not exist, the script asks whether it should create it.

This makes the script portable between different machines and users.

---

# PHP-FPM

The script dynamically detects installed PHP-FPM versions.

For example:

```text
INSTALLED PHP-FPM VERSIONS

  1) PHP 8.1
  2) PHP 8.2
  3) PHP 8.3

Highest installed PHP-FPM version: PHP 8.3
```

The user can select the PHP version.

The script then verifies:

```text
/usr/bin/php8.3
php8.3-fpm
/run/php/php8.3-fpm.sock
```

The Apache VirtualHost is configured to use the selected PHP-FPM socket.

This allows multiple PHP versions to coexist on the same machine.

---

# Composer

The script checks whether Composer is installed.

If Composer is missing, it can install it.

Composer commands are executed explicitly with the selected PHP version rather than relying blindly on the system default PHP.

For example:

```bash
php8.3 composer create-project ...
```

This prevents a common problem where:

```text
PHP-FPM = PHP 8.3
Composer = PHP 8.1
```

causes dependency-resolution or platform-compatibility problems.

---

# Node.js, npm and NVM

The script checks for:

* Node.js
* npm
* NVM

If NVM is already installed for the project owner, the script prefers an appropriate existing NVM-managed Node.js installation.

If a suitable Node.js version is not available, the script can install Node.js LTS.

The user's NVM environment is loaded under the actual project owner rather than root.

This is important because Node packages should normally belong to the user who develops the application, not `root`.

---

# Git

Git is checked as part of the dependency section.

If Git is required and missing, the script can install it.

Git is especially important for:

* GitHub imports
* Laravel package development
* Version control
* Vemto-generated projects

---

# MySQL / MariaDB

The script checks for an active MySQL or MariaDB service.

It creates the requested database automatically.

For example:

```text
Database name: myproject
```

creates:

```text
myproject
```

using:

```text
utf8mb4
```

with:

```text
utf8mb4_unicode_ci
```

---

# Dedicated Database User

The script asks whether to create a dedicated database user.

Example:

```text
Create a dedicated MySQL user for this project? [Y/n]:
```

If accepted:

```text
Database:
    myproject

User:
    myproject_user
```

The user receives privileges only for the project's database.

This is preferable to using the MySQL root account.

The script also safely handles special characters in database passwords, including backslashes and single quotes.

---

# Laravel `.env`

The script creates or configures:

```text
.env
```

with values such as:

```dotenv
APP_NAME=myproject
APP_ENV=local
APP_DEBUG=true
APP_URL=http://myproject.test

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=myproject
DB_USERNAME=myproject_user
DB_PASSWORD=********
```

The `.env` file receives restrictive permissions.

---

# Laravel Permissions

The script configures ownership so that the project developer can work with the application while Apache can access the required files.

Laravel's writable directories receive special treatment:

```text
storage/
bootstrap/cache/
```

These directories are configured to be writable by the Apache web user.

---

# ACL Support

For projects stored inside:

```text
/home/...
```

Apache needs permission to traverse the parent directories.

The script handles this using ACLs where available.

For example:

```text
/home/user
/home/user/www
/home/user/www/project
```

Apache receives traversal permission without unnecessarily granting directory listing access.

Writable Laravel directories also receive appropriate ACL permissions.

If ACL support is unavailable, the script can fall back to group-based permissions and warns the user.

---

# Apache

The script creates a dedicated Apache VirtualHost.

Example:

```apache
<VirtualHost *:80>

    ServerName myproject.test

    DocumentRoot /var/www/myproject/public

    <Directory /var/www/myproject/public>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

</VirtualHost>
```

The Apache modules required by Laravel are enabled when necessary, including:

```text
rewrite
proxy
proxy_fcgi
setenvif
```

---

# Apache Safety

The script validates the Apache configuration **before reloading Apache**.

It runs:

```bash
apache2ctl configtest
```

Actual configuration errors stop the process before Apache is reloaded.

Warnings are handled separately where possible.

This prevents a bad VirtualHost configuration from unnecessarily breaking an existing Apache installation.

---

# Port Checks

Before configuring Apache, the script can check whether ports:

```text
80
443
```

are already being used.

If another service is listening on these ports, the user is warned before continuing.

---

# HTTPS

The script can optionally configure HTTPS for local development using a self-signed certificate.

This is intended for development environments rather than production certificates.

---

# Laravel Verification

For a normal Laravel project, the script verifies the Laravel installation.

It checks:

```bash
php artisan --version
```

and verifies the database connection.

It also clears Laravel configuration/cache before testing the database:

```bash
php artisan config:clear
php artisan cache:clear
```

This avoids testing against stale `.env` configuration.

---

# Final Verification

Before finishing, the script displays a complete status summary.

Example:

```text
============================================================
 FINAL VERIFICATION
============================================================

Project
-------
Name:             myproject
Directory:        /home/user/www/myproject
URL:              http://myproject.test
Type:             Normal Laravel

PHP
---
Selected PHP:     PHP 8.3

PHP-FPM
-------
Service:          php8.3-fpm
Status:           ACTIVE
Socket status:    OK

Apache
------
Configuration:    OK
Service:          ACTIVE

Database
--------
Database:         myproject
Username:         myproject_user
Laravel DB:       OK

HTTP Access
-----------
HTTP Status:      200 (OK)

Permissions
-----------
Owner:            user
Group:            www-data
```

This makes it easy to identify configuration problems immediately.

---

# Dry Run

A dry-run mode is provided for testing what the script intends to do without applying system changes.

Example:

```bash
sudo ./add-laravel-project.sh --dry-run
```

The script should display the operations it would perform without:

* Installing packages
* Modifying Apache
* Creating databases
* Creating users
* Changing permissions
* Writing system configuration

This is particularly useful before running the script on an important machine.

---

# Non-Interactive Mode

For automated environments, the script can support non-interactive execution.

Example:

```bash
sudo ./add-laravel-project.sh --non-interactive
```

Configuration can be supplied through command-line options or environment variables where supported.

Interactive mode remains the default for normal development use.

---

# Logging

Major operations are logged to a protected log file.

The log should contain useful information such as:

```text
PHP detection
Package installation
Apache configuration
Database creation
Laravel installation
GitHub clone
Permission configuration
Final verification
```

Sensitive information such as database passwords should **never** be written to the log.

---

# Installation

## 1. Download the script

Clone the repository:

```bash
git clone https://github.com/oirdimed/laravel_linux.git
```

Enter the directory:

```bash
cd laravel_linux
```

---

## 2. Make the script executable

```bash
chmod +x add-laravel-project.sh
```

---

## 3. Install it system-wide

Optional, but convenient:

```bash
sudo cp add-laravel-project.sh /usr/local/bin/add-laravel-project
sudo chmod 755 /usr/local/bin/add-laravel-project
```

You can then run it from anywhere:

```bash
sudo add-laravel-project
```

---

# Usage

The normal interactive command is:

```bash
sudo add-laravel-project
```

The script will guide you through:

```text
Operating system
        ↓
PHP-FPM detection
        ↓
PHP version selection
        ↓
Laravel version selection
        ↓
Project type
        ↓
Project name
        ↓
Project directory
        ↓
Dependencies
        ↓
Database
        ↓
Apache
        ↓
Permissions
        ↓
Verification
```

---

# Example Workflow

A typical installation might look like:

```text
$ sudo add-laravel-project

Operating system: Debian 12

PHP-FPM versions:

  1) PHP 8.1
  2) PHP 8.3

Select PHP version [default: 2]: 2

Selected PHP: 8.3

Laravel versions:

  1) Laravel 13 [RECOMMENDED]
  2) Laravel 12
  3) Laravel 11

Select Laravel version [default: 1]: 1

Project types:

  1) Normal Laravel
  2) Vemto
  3) GitHub

Select project type [default: 1]: 1

Project name: myproject

Base directory: /home/user/www

Database: myproject

Create dedicated MySQL user? [Y/n]: Y
```

After completion:

```text
http://myproject.test
```

opens the Laravel application.

---

# Security Considerations

This script modifies system-level configuration.

Review it before running it on a production server.

The script is primarily intended for:

* Local development
* Development servers
* Test environments
* Laravel development machines

Important considerations:

* Run only scripts you trust with `sudo`.
* Review generated Apache configuration.
* Do not use self-signed SSL certificates for production.
* Do not use the MySQL root account for production Laravel applications.
* Protect `.env` files.
* Review firewall configuration separately.
* Keep Debian/Ubuntu and PHP packages updated.

---

# Important Assumptions

The script assumes:

* Debian or Ubuntu
* systemd
* Apache 2.4+
* Bash 4+
* MySQL or MariaDB
* A normal Linux user with sudo privileges

The script does **not** use Docker.

It configures Laravel directly on the host system using:

```text
Apache
PHP-FPM
MySQL/MariaDB
Composer
Node.js
npm
Git
```

---

# Troubleshooting

## Script reports a syntax error

Validate the script before running it:

```bash
bash -n add-laravel-project.sh
```

If nothing is returned, the Bash syntax is valid.

You can also inspect the first line:

```bash
head -n 1 add-laravel-project.sh
```

It should be:

```bash
#!/usr/bin/env bash
```

---

## Apache configuration failed

Run:

```bash
sudo apache2ctl configtest
```

Then check:

```bash
sudo systemctl status apache2
```

Apache logs can also be inspected with:

```bash
sudo journalctl -u apache2
```

---

## PHP-FPM is not running

Check the available services:

```bash
systemctl list-units --type=service | grep php
```

Then check the selected version:

```bash
systemctl status php8.3-fpm
```

Replace `8.3` with the installed version.

---

## Laravel cannot connect to MySQL

Check the `.env` file:

```bash
nano .env
```

Verify:

```dotenv
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=...
DB_USERNAME=...
DB_PASSWORD=...
```

Then run:

```bash
php artisan config:clear
php artisan cache:clear
php artisan migrate:status
```

---

## GitHub import fails

Test the repository manually:

```bash
git ls-remote https://github.com/user/project.git
```

For a private repository using SSH:

```bash
git ls-remote git@github.com:user/project.git
```

If SSH authentication fails, configure your GitHub SSH key before importing the project.

---

# Why This Script Exists

Creating a Laravel project manually on Linux often requires repeating the same operations:

```text
Install PHP
Install PHP-FPM
Select PHP version
Install extensions
Install Composer
Install Node
Install npm
Install Git
Create project
Create database
Create database user
Configure .env
Set permissions
Configure ACL
Configure Apache
Configure PHP-FPM
Edit /etc/hosts
Test Apache
Test database
Test HTTP
```

Doing these steps manually increases the chance of configuration mistakes.

This script brings those operations together into a single guided workflow while keeping the configuration explicit and verifiable.

The goal is **not** to hide what happens on the system, but to make the process repeatable, safer, and easier to audit.


---

# Contributing

Contributions are welcome.

Before submitting changes:

1. Test the script on Debian.
2. Test the script on Ubuntu.
3. Validate Bash syntax:

```bash
bash -n add-laravel-project.sh
```

4. Test normal Laravel creation.
5. Test Vemto preparation.
6. Test GitHub import.
7. Test with multiple PHP-FPM versions.
8. Test with `/var/www`.
9. Test with `/home/<user>/www`.
10. Test Apache configuration failure scenarios.
11. Test database connection failure scenarios.
12. Never commit passwords, `.env` files, or private credentials.

---

## License

This project is provided as-is. See the repository's license file for details.
