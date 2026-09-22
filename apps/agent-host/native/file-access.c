#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int forbidden_component(const char *name) {
  return strcmp(name, "") == 0 || strcmp(name, ".") == 0 || strcmp(name, "..") == 0 ||
         strcmp(name, ".git") == 0 || strcmp(name, "node_modules") == 0 ||
         strcmp(name, "DerivedData") == 0 || strcmp(name, ".build") == 0 ||
         strcmp(name, "Pods") == 0;
}

static int open_directory_at(int parent, const char *name) {
  return openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

static int invalid_component(const char *name) {
  return strcmp(name, "") == 0 || strcmp(name, ".") == 0 || strcmp(name, "..") == 0;
}

static int walk_directories(int root, char *path, int enforce_policy) {
  int current = dup(root);
  if (current < 0) return -1;
  if (path[0] == '\0') return current;
  char *state = NULL;
  for (char *component = strtok_r(path, "/", &state); component != NULL;
       component = strtok_r(NULL, "/", &state)) {
    if (invalid_component(component) || (enforce_policy && forbidden_component(component))) {
      errno = EACCES; close(current); return -1;
    }
    int next = open_directory_at(current, component);
    close(current);
    if (next < 0) return -1;
    current = next;
  }
  return current;
}

static int open_root(const char *path) {
  if (path[0] != '/') { errno = EINVAL; return -1; }
  int slash = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (slash < 0) return -1;
  char *components = strdup(path + 1);
  if (components == NULL) { close(slash); return -1; }
  int root = walk_directories(slash, components, 0);
  free(components);
  close(slash);
  return root;
}

static int list_directory(int descriptor) {
  DIR *directory = fdopendir(descriptor);
  if (directory == NULL) { close(descriptor); return -1; }
  struct dirent *entry;
  while ((entry = readdir(directory)) != NULL) {
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0 ||
        forbidden_component(entry->d_name)) continue;
    struct stat metadata;
    if (fstatat(dirfd(directory), entry->d_name, &metadata, AT_SYMLINK_NOFOLLOW) != 0) continue;
    char kind = S_ISDIR(metadata.st_mode) ? 'D' : S_ISREG(metadata.st_mode) ? 'F' : '\0';
    if (kind == '\0') continue;
    if (printf("%c\t%lld\t", kind, (long long)metadata.st_size) < 0 ||
        fwrite(entry->d_name, 1, strlen(entry->d_name), stdout) != strlen(entry->d_name) ||
        fputc('\0', stdout) == EOF) {
      closedir(directory);
      return -1;
    }
  }
  return closedir(directory);
}

static int read_file(int directory, const char *name) {
  if (forbidden_component(name)) { errno = EACCES; return -1; }
  int file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (file < 0) return -1;
  struct stat metadata;
  if (fstat(file, &metadata) != 0 || !S_ISREG(metadata.st_mode)) {
    if (errno == 0) errno = EISDIR;
    close(file);
    return -1;
  }
  char buffer[65536];
  ssize_t count;
  while ((count = read(file, buffer, sizeof(buffer))) > 0) {
    if (fwrite(buffer, 1, (size_t)count, stdout) != (size_t)count) { close(file); return -1; }
  }
  int saved = errno;
  close(file);
  errno = saved;
  return count < 0 ? -1 : 0;
}

int main(int argc, char **argv) {
  if (argc != 4 || (strcmp(argv[1], "list") != 0 && strcmp(argv[1], "read") != 0)) return 64;
  int root = open_root(argv[2]);
  if (root < 0) { perror("project root"); return 1; }
  char *path = strdup(argv[3]);
  if (path == NULL) { close(root); return 1; }
  int result = -1;
  if (strcmp(argv[1], "list") == 0) {
    int directory = walk_directories(root, path, 1);
    if (directory >= 0) result = list_directory(directory);
  } else {
    char *name = strrchr(path, '/');
    char *parentPath = path;
    if (name == NULL) { name = path; parentPath = path + strlen(path); }
    else { *name = '\0'; name += 1; }
    int directory = walk_directories(root, parentPath, 1);
    if (directory >= 0) { result = read_file(directory, name); close(directory); }
  }
  if (result != 0) perror("file access");
  free(path);
  close(root);
  return result == 0 ? 0 : 1;
}
