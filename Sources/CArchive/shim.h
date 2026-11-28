// The libarchive functions Folio calls, declared by hand: macOS ships
// /usr/lib/libarchive.2.dylib and the SDK has libarchive.tbd, but no headers.
// Prototypes follow libarchive 3.x's public API (archive.h, archive_entry.h).
// Add a declaration here before calling a new function.
#include <stdint.h>
#include <sys/types.h>

struct archive;
struct archive_entry;

#define ARCHIVE_EOF 1
#define ARCHIVE_OK 0
#define ARCHIVE_WARN (-20)

const char *archive_error_string(struct archive *);

// Reading
struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_free(struct archive *);

// Writing
struct archive *archive_write_new(void);
int archive_write_set_format_by_name(struct archive *, const char *name);
int archive_write_open_filename(struct archive *, const char *filename);
int archive_write_header(struct archive *, struct archive_entry *);
ssize_t archive_write_data(struct archive *, const void *, size_t);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);

// Entries
struct archive_entry *archive_entry_new(void);
void archive_entry_free(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
void archive_entry_set_pathname(struct archive_entry *, const char *);
void archive_entry_set_size(struct archive_entry *, int64_t);
void archive_entry_set_filetype(struct archive_entry *, unsigned int);
void archive_entry_set_perm(struct archive_entry *, mode_t);
