# [Laravel](https://laravel.com)  Project Setup Script

A Bash script that automates the creation and configuration of **Laravel applications on Debian and Ubuntu**.

It is designed for developers who work with multiple Laravel projects and want a consistent environment with:

* Multiple PHP versions
* PHP-FPM
* Apache
* MySQL/MariaDB
* Composer
* Local `.test` domains
* Automatic database creation
* Dedicated database users
* Correct Laravel permissions
* Normal Laravel projects
*  [Vemto-generated](https://vemto.app)  Laravel projects

The script is interactive and dynamically adapts to the software installed on the machine.

---

# Why this script?

Creating a Laravel project manually on Linux involves many configuration steps.

For every new application, you may need to:

1. Check the installed PHP versions
2. Install PHP and PHP-FPM if necessary
3. Select the PHP version for the application
4. Determine a compatible Laravel version
5. Install Laravel with Composer
6. Create a MySQL/MariaDB database
7. Create a dedicated database user
8. Create and configure `.env`
9. Generate the Laravel application key
10. Configure Apache
11. Configure PHP-FPM
12. Create a local `.test` domain
13. Configure `/etc/hosts`
14. Configure Laravel permissions
15. Configure `storage` and `bootstrap/cache`
16. Reload Apache

Doing this manually for every application is repetitive and can easily lead to configuration and permission problems.

This script automates these tasks through a guided setup.

---

# Main Features

## Dynamic PHP detection

The script does not assume that a particular PHP version is installed.

It checks the machine for available PHP-FPM versions.

For example:

```text
============================================================
 INSTALLED PHP-FPM VERSIONS
============================================================

  1) PHP 8.1
  2) PHP 8.2
  3) PHP 8.3

[INFO] Highest installed PHP-FPM version: PHP 8.3

Select PHP version [default: 3 - PHP 8.3]:
```

The highest installed PHP-FPM version is automatically recommended.

The user can select another installed version if required.

---

# PHP installation when necessary

The script is designed to work on different Debian or Ubuntu machines.

If PHP is not installed, or if the required PHP-FPM components are missing, the script can detect the situation and offer to install the required packages before continuing.

This prevents the script from assuming that a particular PHP version already exists.

---

# Laravel version selection

After selecting the PHP version, the script determines the Laravel versions compatible with that PHP version.

It then presents the user with a recommended Laravel version.

Example:

```text
============================================================
 LARAVEL VERSION
============================================================

PHP selected: PHP 8.3

Recommended Laravel version: Laravel X

Available compatible Laravel versions:

  1) Laravel X (recommended)
  2) Laravel X
  3) Laravel X

Select Laravel version [default: 1]:
```

The purpose is to avoid creating a Laravel application that requires a PHP version different from the PHP version selected for the project.

---

# Two project modes

The script supports two different project creation workflows.

```text
============================================================
 PROJECT TYPE
============================================================

  1) Normal Laravel project
  2) Vemto project

Select project type [default: 1]:
```

---

## 1. Normal Laravel project

In Normal Laravel mode, the script creates the Laravel application automatically using Composer.

Composer is executed using the **selected PHP version**.

This is important when several PHP versions are installed.

For example:

```text
PHP 8.1
PHP 8.2
PHP 8.3
```

If the user selects PHP 8.3, Composer should run using PHP 8.3 rather than relying on the system's default `php` command.

The project is then created with the selected Laravel version.

---

## 2. Vemto project

Vemto follows a different workflow because Vemto generates the Laravel application itself.

In Vemto mode, the script prepares the development environment without creating a second Laravel skeleton.

It configures:

* Project directory
* Apache VirtualHost
* PHP-FPM
* MySQL/MariaDB database
* Database user
* `.env` when appropriate
* Local `.test` domain
* File ownership
* ACL permissions

Vemto can then generate the Laravel application into the prepared project directory.

This prevents conflicts between Composer's Laravel installation and Vemto's own generation process.

---

# Dynamic project directory

The script does not force users to store their applications in `/var/www`.

The user is asked to choose the base directory.

The default suggestion is:

```text
Enter base directory for projects [/var/www]:
```

Pressing `Enter` uses:

```text
/var/www
```

The user can instead specify another directory:

```text
/home/user/www
```

or:

```text
/home/user/projects
```

or:

```text
/srv/www
```

This makes the script suitable for different development environments.

---

# Apache VirtualHost

For every project, the script creates an Apache VirtualHost.

For a project named:

```text
myapp
```

the local domain becomes:

```text
myapp.test
```

The Apache document root points to Laravel's:

```text
public/
```

directory.

For example:

```text
/home/user/www/myapp/public
```

This is important because Laravel applications should not expose the project root directly.

---

# PHP-FPM per project

Each VirtualHost is configured to use the PHP-FPM version selected for that project.

For example:

```text
app1.test → PHP 8.1
app2.test → PHP 8.3
app3.test → PHP 8.2
```

This allows multiple Laravel applications using different PHP versions to run simultaneously on the same machine.

The Apache configuration uses the corresponding PHP-FPM socket.

Example:

```apache
SetHandler "proxy:unix:/run/php/php8.3-fpm.sock|fcgi://localhost/"
```

---

# Local `.test` domains

The script automatically adds the project's local domain to:

```text
/etc/hosts
```

For example:

```text
127.0.0.1    myapp.test
```

The application can then be accessed from a browser using:

```text
http://myapp.test
```

No external DNS configuration is required.

---

# MySQL/MariaDB database

The script automatically creates a database for the application.

For example:

```text
Project name:
myapp
```

Database:

```text
myapp
```

The script can also create a dedicated database user.

Example:

```text
myapp_user
```

This is preferable to using the MySQL/MariaDB `root` account from the Laravel application.

The database credentials are written to the project's `.env` file.

---

# Laravel `.env`

The script creates and configures the `.env` file when appropriate.

Typical configuration:

```env
APP_ENV=local
APP_DEBUG=true
APP_URL=http://myapp.test

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=myapp
DB_USERNAME=myapp_user
DB_PASSWORD=********
```

The Laravel application key is generated after the project permissions have been configured.

---

# Permission management

One of the most important features of the script is Laravel permission management.

Linux development environments commonly have two users interacting with the application:

```text
Developer
    │
    └── Project files

Apache
    │
    └── www-data
```

If the permissions are not configured correctly, Apache can return:

```text
403 Forbidden
```

Laravel can also produce errors such as:

```text
Permission denied
```

when attempting to write to:

```text
storage/
```

or:

```text
bootstrap/cache/
```

The script is designed to avoid these problems.

---

# Developer ownership

The project remains owned by the normal development user.

Apache receives the access it needs through the appropriate group and ACL configuration.

The goal is:

```text
Developer → owns and edits the project
www-data  → accesses and writes where Laravel requires it
```

This prevents the common situation where Apache creates files owned by `www-data`, after which the developer cannot easily modify or delete them.

---

# No `chmod 777`

The script intentionally avoids using:

```bash
chmod -R 777
```

as a solution to permission problems.

Instead, it uses:

* Ownership
* Groups
* Directory permissions
* ACLs where appropriate

This provides the required access without making the entire project world-writable.

---

# Laravel writable directories

Laravel requires certain directories to be writable.

The script handles:

```text
storage/
bootstrap/cache/
```

when they exist.

For a Normal Laravel project, these directories are created by Laravel during project creation.

For a Vemto project, they may not exist yet when the initial environment is prepared.

The script therefore does not assume that these directories already exist.

Permissions are applied at the appropriate stage after the Laravel application structure is available.

---

# Composer and PHP version

A machine may have several PHP versions installed.

For example:

```text
PHP 7.4
PHP 8.1
PHP 8.2
PHP 8.3
```

The system's default PHP CLI version might not be the same version selected for the project.

Therefore, the script ensures Composer is executed with the selected PHP version.

Conceptually:

```bash
php8.3 composer create-project ...
```

rather than blindly relying on:

```bash
php composer create-project ...
```

This reduces PHP version mismatch problems.

---

# Apache requirements

The script checks that Apache is available and requires Apache 2.4 or newer.

Required Apache modules include:

```text
rewrite
proxy
proxy_fcgi
setenvif
```

The script enables missing modules when necessary.

After configuration, Apache is reloaded.

---

# MySQL/MariaDB security

The script supports creating a dedicated database account for each project.

Instead of:

```text
Laravel → root
```

the preferred configuration is:

```text
Laravel → project-specific database user
```

For example:

```text
myapp
myapp_user
```

This limits the application's database privileges to its own database.

---

# Idempotent design

The script attempts to avoid unnecessary destructive operations when configuration already exists.

For example, it checks whether:

* The project directory exists
* `.env` already exists
* The VirtualHost already exists
* The site is already enabled
* The `/etc/hosts` entry already exists
* The PHP-FPM service is already running
* The database already exists

This makes it safer to rerun during development.

---

# Requirements

Supported operating systems:

* Debian
* Ubuntu

The script expects a system using:

* Bash
* systemd
* Apache 2.4+
* MySQL or MariaDB
* Composer
* PHP
* PHP-FPM

Additional PHP packages may be installed depending on the Laravel version selected.

The script dynamically checks the environment rather than assuming that one fixed PHP version is available.

---

# Installation

Clone the repository:

```bash
git clone https://github.com/YOUR-USERNAME/YOUR-REPOSITORY.git
```

Enter the repository:

```bash
cd YOUR-REPOSITORY
```

Make the script executable:

```bash
chmod +x add-laravel-project.sh
```

You can run it directly:

```bash
sudo ./add-laravel-project.sh
```

---

# Optional: Install the command globally

To make the command available from anywhere:

```bash
sudo cp add-laravel-project.sh /usr/local/bin/add-laravel-project
```

Then:

```bash
sudo chmod +x /usr/local/bin/add-laravel-project
```

You can now run:

```bash
sudo add-laravel-project
```

from any directory.

---

# Usage

Start the script:

```bash
sudo add-laravel-project
```

The script will guide you through the configuration.

Typical workflow:

```text
1. Select project type
2. Enter project name
3. Select project directory
4. Detect PHP-FPM versions
5. Select PHP version
6. Select compatible Laravel version
7. Configure database
8. Create database user
9. Configure Apache
10. Configure local domain
11. Configure permissions
12. Finish project setup
```

---

# Example workflow

Create a project called:

```text
myapp
```

Run:

```bash
sudo add-laravel-project
```

Select:

```text
1) Normal Laravel project
```

Enter:

```text
Project name: myapp
```

Choose the project directory:

```text
Enter base directory for projects [/var/www]:
```

For example:

```text
/home/user/www
```

Select the PHP version:

```text
PHP 8.3
```

Select the recommended compatible Laravel version.

The script then creates the application and configures the environment.

The result will be similar to:

```text
/home/user/www/myapp
```

with:

```text
myapp.test
```

available at:

```text
http://myapp.test
```

---

# Vemto workflow

To prepare a project for Vemto:

```bash
sudo add-laravel-project
```

Select:

```text
2) Vemto project
```

Choose the project directory and PHP version.

The script prepares the infrastructure.

Then use Vemto to generate the Laravel application into the selected project directory.

This approach is useful when Vemto is responsible for generating:

* Models
* Migrations
* Controllers
* CRUDs
* Relationships
* Seeders
* Laravel application code

while this script handles the underlying Linux development environment.

---

# Multiple applications

The script is designed to make running multiple Laravel applications easier.

For example:

```text
/var/www/app1
/var/www/app2
/home/user/www/app3
/home/user/www/app4
```

Each application can have its own:

```text
.test domain
PHP-FPM version
MySQL database
MySQL user
Apache VirtualHost
```

Example:

```text
app1.test → PHP 8.1
app2.test → PHP 8.3
app3.test → PHP 8.2
```

All applications can run simultaneously.

---

# Troubleshooting

## Check Apache configuration

```bash
sudo apache2ctl configtest
```

Expected result:

```text
Syntax OK
```

---

## Check Apache status

```bash
sudo systemctl status apache2
```

---

## Check PHP-FPM

For example:

```bash
sudo systemctl status php8.3-fpm
```

---

## Check PHP-FPM sockets

```bash
ls -l /run/php/
```

You should see sockets similar to:

```text
php8.1-fpm.sock
php8.2-fpm.sock
php8.3-fpm.sock
```

---

## Check project permissions

From the project directory:

```bash
ls -ld .
ls -ld storage bootstrap/cache
```

---

## Check the Apache error log

For a project named `myapp`:

```bash
sudo tail -n 50 /var/log/apache2/myapp_test_error.log
```

---

## Check Laravel configuration

Inside the project:

```bash
php artisan about
```

and:

```bash
php artisan config:clear
```

---

# Security Notes

This script is primarily intended for **local development environments**.

It modifies system configuration such as:

```text
/etc/hosts
/etc/apache2/sites-available/
Apache modules
PHP-FPM services
MySQL/MariaDB
```

Therefore, it must be run with `sudo`.

Review the script before executing it on an important machine.

Do not use automatically generated development configurations as a replacement for a proper production deployment strategy.

---

# Design Principles

The script follows several principles.

## 1. Detect instead of assuming

The script should not assume that a specific PHP version is installed.

It detects the available environment dynamically.

---

## 2. Use the highest suitable PHP version

When several PHP-FPM versions are installed, the highest available version is recommended by default.

The user can still select another installed version.

---

## 3. Match Laravel to PHP

The Laravel version should be compatible with the selected PHP version.

The user is shown the recommended Laravel version rather than having a fixed Laravel version hardcoded into the script.

---

## 4. Keep project ownership with the developer

The developer should remain the owner of the project files.

Apache receives only the access it needs.

---

## 5. Avoid `777`

Permissions should be solved using proper Linux ownership, groups and ACLs rather than making the project world-writable.

---

## 6. Support different development environments

The script should work whether the developer uses:

```text
/var/www
/home/user/www
/home/user/projects
/srv/www
```

or another suitable directory.

---

## 7. Support both Composer and Vemto

Normal Laravel projects are created with Composer.

Vemto projects are prepared for Vemto to generate the Laravel application.

This avoids mixing two different project-generation workflows.

---

# Contributing

Contributions, bug reports and improvements are welcome.

If you encounter an issue, please provide:

* Debian/Ubuntu version
* PHP versions installed
* PHP-FPM versions installed
* Laravel version
* Apache version
* MySQL/MariaDB version
* Relevant error message

This makes compatibility issues easier to reproduce and fix.

---

# License

Choose and add the license you want to use for this project.

For example:

```text
MIT License
```

---

# Quick Start

```bash
git clone https://github.com/YOUR-USERNAME/YOUR-REPOSITORY.git
cd YOUR-REPOSITORY
chmod +x add-laravel-project.sh
sudo ./add-laravel-project.sh
```

Or install it globally:

```bash
sudo cp add-laravel-project.sh /usr/local/bin/add-laravel-project
sudo chmod +x /usr/local/bin/add-laravel-project
sudo add-laravel-project
```

Then follow the interactive prompts.

Your Laravel application will be configured with its own:

```text
Project directory
PHP-FPM version
Laravel version
Apache VirtualHost
.test domain
Database
Database user
.env
Permissions
```

The goal is simple:

> **Create a new Laravel development environment with one guided command, without repeating the same Linux configuration work for every project.**
> 
