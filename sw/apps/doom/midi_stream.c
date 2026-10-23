// midi_stream.c (GPL v2, like Chocolate Doom) - src/midifile.h API (Chocolate Doom) that reads the MIDI
// events on the fly.
//   midifile.c converts each track into a table of midi_event_t (20 bytes per
//   event): with the long Doom 2 songs (~20000 events) that is ~400 KB
//   and does not fit in what is left for malloc. Here a copy of the
//   MIDI file (≤ ~100 KB) is kept and each iterator decodes the next event
//   when asked. Meta-event data points into the copy.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "src/doomtype.h"
#include "src/midifile.h"

typedef struct
{
    const byte *data;
    unsigned int len;
} midi_track_t;

struct midi_file_s
{
    byte *raw;
    short time_division;
    midi_track_t *tracks;
    unsigned int num_tracks;
};

struct midi_track_iter_s
{
    const midi_track_t *track;
    unsigned int pos, status;           // next byte and "running status"
    unsigned int next_pos, next_status; // start of the 'next' event (loop point)
    unsigned int loop_pos, loop_status;
    boolean have_next, ended;
    midi_event_t next, cur;
};

static unsigned int be16(const byte *p) { return (p[0] << 8) | p[1]; }
static unsigned int be32(const byte *p) { return ((unsigned int)p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]; }

midi_file_t *MIDI_LoadMem(void *data, size_t len)
{
    const byte *d = data;
    unsigned int format, ntr, i, p;
    midi_file_t *file;

    if (len < 14 || memcmp(d, "MThd", 4) != 0 || be32(d + 4) != 6)
    {
        fprintf(stderr, "MIDI_LoadMem: Invalid MIDI chunk header\n");
        return NULL;
    }
    format = be16(d + 8);
    ntr = be16(d + 10);
    if ((format != 0 && format != 1) || ntr < 1)
    {
        fprintf(stderr, "MIDI_LoadMem: Only type 0/1 MIDI files supported\n");
        return NULL;
    }
    file = calloc(1, sizeof(*file));
    if (file == NULL)
        return NULL;
    file->raw = malloc(len);
    file->tracks = calloc(ntr, sizeof(midi_track_t));
    if (file->raw == NULL || file->tracks == NULL)
    {
        MIDI_FreeFile(file);
        return NULL;
    }
    memcpy(file->raw, d, len);
    file->time_division = (short)be16(d + 12);
    file->num_tracks = ntr;
    p = 14;
    for (i = 0; i < ntr; ++i)
    {
        unsigned int sz;
        if (p + 8 > len || memcmp(file->raw + p, "MTrk", 4) != 0)
        {
            fprintf(stderr, "MIDI_LoadMem: Invalid track chunk header\n");
            MIDI_FreeFile(file);
            return NULL;
        }
        sz = be32(file->raw + p + 4);
        if (sz > len - p - 8)
            sz = len - p - 8;
        file->tracks[i].data = file->raw + p + 8;
        file->tracks[i].len = sz;
        p += 8 + sz;
    }
    return file;
}

void MIDI_FreeFile(midi_file_t *file)
{
    if (file == NULL)
        return;
    free(file->raw);
    free(file->tracks);
    free(file);
}

unsigned int MIDI_GetFileTimeDivision(midi_file_t *file)
{
    short result = file->time_division;

    // Negative time division indicates SMPTE time and must be handled
    // differently.
    if (result < 0)
        return (signed int)(-(result / 256)) * (signed int)(result & 0xFF);
    return result;
}

unsigned int MIDI_NumTracks(midi_file_t *file)
{
    return file->num_tracks;
}

midi_track_iter_t *MIDI_IterateTrack(midi_file_t *file, unsigned int track)
{
    midi_track_iter_t *iter;

    if (track >= file->num_tracks)
        return NULL;
    iter = malloc(sizeof(*iter));
    if (iter == NULL)
        return NULL;
    iter->track = &file->tracks[track];
    MIDI_RestartIterator(iter);
    return iter;
}

void MIDI_FreeIterator(midi_track_iter_t *iter)
{
    free(iter);
}

// ---------------------------------------------------------------- reading
static boolean GetByte(midi_track_iter_t *it, byte *b)
{
    if (it->pos >= it->track->len)
        return false;
    *b = it->track->data[it->pos++];
    return true;
}

static boolean GetVarLen(midi_track_iter_t *it, unsigned int *v)
{
    byte b;
    int i;

    *v = 0;
    for (i = 0; i < 4; ++i)
    {
        if (!GetByte(it, &b))
            return false;
        *v = (*v << 7) | (b & 0x7F);
        if ((b & 0x80) == 0)
            return true;
    }
    return false;                       // more than 4 bytes
}

// decodes the event at it->pos into it->next; if the track ends without
// "end of track" (or is damaged) one is made up, as if it were there
static void DecodeNext(midi_track_iter_t *it)
{
    midi_event_t *e = &it->next;
    byte type, b;
    unsigned int len;

    it->next_pos = it->pos;
    it->next_status = it->status;
    it->have_next = true;
    if (!GetVarLen(it, &e->delta_time) || !GetByte(it, &type))
        goto end_of_track;
    if ((type & 0x80) == 0)             // "running status": the byte is data
    {
        type = (byte)it->status;
        it->pos--;
    }
    else
    {
        it->status = type;
    }
    switch (type & 0xF0)
    {
    case MIDI_EVENT_NOTE_OFF:
    case MIDI_EVENT_NOTE_ON:
    case MIDI_EVENT_AFTERTOUCH:
    case MIDI_EVENT_CONTROLLER:
    case MIDI_EVENT_PITCH_BEND:
    case MIDI_EVENT_PROGRAM_CHANGE:
    case MIDI_EVENT_CHAN_AFTERTOUCH:
        e->event_type = type & 0xF0;
        e->data.channel.channel = type & 0x0F;
        if (!GetByte(it, &b))
            goto end_of_track;
        e->data.channel.param1 = b;
        if ((type & 0xF0) != MIDI_EVENT_PROGRAM_CHANGE && (type & 0xF0) != MIDI_EVENT_CHAN_AFTERTOUCH)
        {
            if (!GetByte(it, &b))
                goto end_of_track;
            e->data.channel.param2 = b;
        }
        return;
    default:
        break;
    }
    switch (type)
    {
    case MIDI_EVENT_SYSEX:
    case MIDI_EVENT_SYSEX_SPLIT:
        e->event_type = type;
        if (!GetVarLen(it, &len) || len > it->track->len - it->pos)
            goto end_of_track;
        e->data.sysex.length = len;
        e->data.sysex.data = (byte *)it->track->data + it->pos;
        it->pos += len;
        return;
    case MIDI_EVENT_META:
        e->event_type = MIDI_EVENT_META;
        if (!GetByte(it, &b) || !GetVarLen(it, &len) || len > it->track->len - it->pos)
            goto end_of_track;
        e->data.meta.type = b;
        e->data.meta.length = len;
        e->data.meta.data = (byte *)it->track->data + it->pos;
        it->pos += len;
        return;
    default:
        fprintf(stderr, "MIDI: Unknown MIDI event type: 0x%x\n", type);
        break;
    }
end_of_track:
    e->delta_time = 0;
    e->event_type = MIDI_EVENT_META;
    e->data.meta.type = MIDI_META_END_OF_TRACK;
    e->data.meta.length = 0;
    e->data.meta.data = NULL;
    it->pos = it->track->len;
}

unsigned int MIDI_GetDeltaTime(midi_track_iter_t *iter)
{
    if (iter->ended)
        return 0;
    if (!iter->have_next)
        DecodeNext(iter);
    return iter->next.delta_time;
}

int MIDI_GetNextEvent(midi_track_iter_t *iter, midi_event_t **event)
{
    if (iter->ended)
        return 0;
    if (!iter->have_next)
        DecodeNext(iter);
    iter->cur = iter->next;
    iter->have_next = false;
    if (iter->cur.event_type == MIDI_EVENT_META && iter->cur.data.meta.type == MIDI_META_END_OF_TRACK)
        iter->ended = true;
    *event = &iter->cur;
    return 1;
}

void MIDI_RestartIterator(midi_track_iter_t *iter)
{
    iter->pos = 0;
    iter->status = 0;
    iter->have_next = false;
    iter->ended = false;
    iter->loop_pos = 0;
    iter->loop_status = 0;
}

void MIDI_SetLoopPoint(midi_track_iter_t *iter)
{
    // the loop point is the event that would be read next
    iter->loop_pos = iter->have_next ? iter->next_pos : iter->pos;
    iter->loop_status = iter->have_next ? iter->next_status : iter->status;
}

void MIDI_RestartAtLoopPoint(midi_track_iter_t *iter)
{
    iter->pos = iter->loop_pos;
    iter->status = iter->loop_status;
    iter->have_next = false;
    iter->ended = false;
}
