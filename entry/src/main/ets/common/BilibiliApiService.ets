import { http } from '@kit.NetworkKit';

/** Python 后端返回的 Bilibili 视频搜索结果。 */
export interface BilibiliSearchItem {
  type: string;
  bvid: string;
  aid: number;
  title: string;
  author: string;
  description: string;
  cover: string;
  duration: string;
  play: number;
  pubdate: number;
  url: string;
}

export interface BilibiliSearchResult {
  keyword: string;
  page: number;
  page_size: number;
  total: number;
  pages: number;
  items: BilibiliSearchItem[];
}

export interface AudioMetadata {
  bvid: string;
  title: string;
  duration_ms: number;
  content_type: string;
  extension: string;
  stream_url: string;
  stream_kind: string;
}

export interface DownloadRecord {
  id: number;
  bvid?: string;
  title: string;
  status: string;
  progress: number;
  local_path?: string;
  file_size: number;
  error_message?: string;
  created_at: number;
  updated_at: number;
}

export interface CreateDownloadRequest {
  bvid?: string;
  title: string;
  status?: string;
  progress?: number;
  local_path?: string;
  file_size?: number;
  error_message?: string;
}

export interface UpdateDownloadRequest {
  status?: string;
  progress?: number;
  local_path?: string;
  file_size?: number;
  error_message?: string;
}

export interface DownloadActionResponse {
  id: number;
  title?: string;
  status?: string;
  updated?: boolean;
  deleted?: boolean;
}

export interface DownloadListResponse {
  items: DownloadRecord[];
}

export interface HistoryRecord {
  id: number;
  bvid?: string;
  title?: string;
  uri?: string;
  keyword?: string;
  position_ms?: number;
  duration_ms?: number;
  page?: number;
  result_count?: number;
  played_at?: number;
  created_at?: number;
}

export interface HistoryListResponse {
  items: HistoryRecord[];
}

export interface PlayHistoryRequest {
  title: string;
  bvid?: string;
  uri?: string;
  position_ms: number;
  duration_ms: number;
}

/**
 * Music Player 对 Python/FastAPI 后端的唯一调用入口。
 *
 * 默认地址适用于真机/模拟器无法直接访问本机时的替换场景：
 * - Android/HarmonyOS 模拟器通常需要使用宿主机映射地址；
 * - 真机需要填写运行 Python 后端的电脑局域网 IP，例如 http://192.168.1.10:8000。
 * 页面只需持有一个实例，不需要自己拼接后端 URL。
 */
export class BilibiliApiService {
  private readonly baseUrl: string;

  constructor(baseUrl: string = 'http://10.0.2.2:8000') {
    this.baseUrl = baseUrl.replace(/\/$/, '');
  }

  private async request(path: string, method: http.RequestMethod = http.RequestMethod.GET,
    body?: object): Promise<Object> {
    const client = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method,
        header: {
          'Content-Type': 'application/json',
          'Accept': 'application/json'
        },
        connectTimeout: 10000,
        readTimeout: 30000
      };
      if (body !== undefined) {
        options.extraData = JSON.stringify(body);
      }
      const response = await client.request(`${this.baseUrl}${path}`, options);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`Backend request failed: ${response.responseCode}`);
      }
      if (typeof response.result === 'string') {
        return JSON.parse(response.result) as Object;
      }
      return response.result as Object;
    } finally {
      client.destroy();
    }
  }

  /** 检查 Python 后端是否在线。 */
  async health(): Promise<boolean> {
    try {
      await this.request('/api/health');
      return true;
    } catch (_) {
      return false;
    }
  }

  /** 搜索 Bilibili 视频。无需登录。 */
  async search(keyword: string, page: number = 1, order: string = 'totalrank'): Promise<BilibiliSearchResult> {
    const query = `?keyword=${encodeURIComponent(keyword)}&page=${page}&order=${encodeURIComponent(order)}`;
    return await this.request(`/api/search${query}`) as BilibiliSearchResult;
  }

  /** 获取前端下载所需元数据，不暴露 Bilibili 临时 URL。 */
  async getAudioMetadata(bvid: string, quality: number = 30280): Promise<AudioMetadata> {
    return await this.request(`/api/videos/${encodeURIComponent(bvid)}/audio/metadata?quality=${quality}`) as AudioMetadata;
  }

  /** 获取本项目代理下载地址，可直接交给 AVPlayer 或下载器。 */
  getAudioStreamUrl(bvid: string, quality: number = 30280): string {
    return `${this.baseUrl}/api/videos/${encodeURIComponent(bvid)}/audio?quality=${quality}`;
  }

  async createDownload(payload: CreateDownloadRequest): Promise<DownloadActionResponse> {
    return await this.request('/api/downloads', http.RequestMethod.POST, payload) as DownloadActionResponse;
  }

  async getDownload(id: number): Promise<DownloadRecord> {
    return await this.request(`/api/downloads/${id}`) as DownloadRecord;
  }

  async listDownloads(limit: number = 50): Promise<DownloadListResponse> {
    return await this.request(`/api/downloads?limit=${limit}`) as DownloadListResponse;
  }

  async updateDownload(id: number, payload: UpdateDownloadRequest): Promise<DownloadActionResponse> {
    return await this.request(`/api/downloads/${id}`, 'PATCH' as http.RequestMethod, payload) as DownloadActionResponse;
  }

  async deleteDownload(id: number): Promise<DownloadActionResponse> {
    return await this.request(`/api/downloads/${id}`, http.RequestMethod.DELETE) as DownloadActionResponse;
  }

  async addPlayHistory(title: string, bvid?: string, uri?: string, positionMs: number = 0,
    durationMs: number = -1): Promise<DownloadActionResponse> {
    const payload: PlayHistoryRequest = {
      title,
      bvid,
      uri,
      position_ms: positionMs,
      duration_ms: durationMs
    };
    return await this.request('/api/history/play', http.RequestMethod.POST, payload) as DownloadActionResponse;
  }

  async getPlayHistory(limit: number = 50): Promise<HistoryListResponse> {
    return await this.request(`/api/history/play?limit=${limit}`) as HistoryListResponse;
  }

  async getSearchHistory(limit: number = 50): Promise<HistoryListResponse> {
    return await this.request(`/api/history/search?limit=${limit}`) as HistoryListResponse;
  }

  /** 组装给页面使用的绝对下载 URL。 */
  resolveStreamUrl(relativeUrl: string): string {
    return relativeUrl.startsWith('http://') || relativeUrl.startsWith('https://')
      ? relativeUrl
      : `${this.baseUrl}${relativeUrl.startsWith('/') ? '' : '/'}${relativeUrl}`;
  }
}
