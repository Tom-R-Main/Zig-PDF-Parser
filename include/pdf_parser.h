#ifndef PDF_PARSER_H
#define PDF_PARSER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PDF_PARSER_ABI_VERSION 2u

typedef enum PdfParserAdaptiveFormat {
    PDF_PARSER_FORMAT_JSON = 0,
    PDF_PARSER_FORMAT_ARTIFACT_JSONL = 1,
    PDF_PARSER_FORMAT_STREAM_JSONL = 2,
    PDF_PARSER_FORMAT_TRACE_JSON = 3,
} PdfParserAdaptiveFormat;

typedef enum PdfParserStatus {
    PDF_PARSER_STATUS_OK = 0,
    PDF_PARSER_STATUS_INVALID_ARGUMENT = 1,
    PDF_PARSER_STATUS_OPEN_ERROR = 2,
    PDF_PARSER_STATUS_EXTRACT_ERROR = 3,
} PdfParserStatus;

typedef struct PdfParserAdaptiveOptions {
    uint32_t abi_version;
    int32_t format;
    const char *input_path;
    const char *document_id;
    const char *source_id;
    const char *password;
    const char *password_file;
    int64_t page_start;
    int64_t page_end;
    uint8_t strict;
    uint8_t permissive;
    const char *debug_assets_dir;
    const char *emit_specialist_requests_path;
    const char *specialist_config_path;
} PdfParserAdaptiveOptions;

typedef struct PdfParserAdaptiveResult {
    int32_t status;
    uint8_t *output;
    size_t output_len;
    uint8_t *error_message;
    size_t error_len;
    const char *schema_version;
    size_t schema_version_len;
    uint32_t warning_count;
} PdfParserAdaptiveResult;

const char *pdf_parser_version(void);
uint32_t pdf_parser_abi_version(void);
void pdf_parser_free_buffer(uint8_t *ptr, size_t len);
void pdf_parser_result_clear(PdfParserAdaptiveResult *result);
int32_t pdf_parser_extract_adaptive_file(const PdfParserAdaptiveOptions *options, PdfParserAdaptiveResult *result);
int32_t pdf_parser_extract_adaptive_memory(const PdfParserAdaptiveOptions *options, const uint8_t *data, size_t data_len, PdfParserAdaptiveResult *result);

#ifdef __cplusplus
}
#endif

#endif
