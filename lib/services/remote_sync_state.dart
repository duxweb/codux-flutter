class RemoteSyncState {
  bool projectListLoaded = false;
  bool terminalListLoaded = false;
  int projectListRetryAttempt = 0;
  int terminalListRetryAttempt = 0;

  void beginConnectionGeneration() {
    projectListLoaded = false;
    terminalListLoaded = false;
    projectListRetryAttempt = 0;
    terminalListRetryAttempt = 0;
  }

  void markProjectListReceived() {
    projectListLoaded = true;
    projectListRetryAttempt = 0;
  }

  void markTerminalListReceived() {
    terminalListLoaded = true;
    terminalListRetryAttempt = 0;
  }

  bool shouldRequestProjectList({bool force = false}) {
    return force || !projectListLoaded;
  }

  bool shouldRequestTerminalList({bool force = false}) {
    return force || !terminalListLoaded;
  }

  bool canRetryProjectList(int maxAttempts) {
    return !projectListLoaded && projectListRetryAttempt < maxAttempts;
  }

  bool canRetryTerminalList(int maxAttempts) {
    return !terminalListLoaded && terminalListRetryAttempt < maxAttempts;
  }

  int nextProjectListRetryAttempt() {
    projectListRetryAttempt += 1;
    return projectListRetryAttempt;
  }

  int nextTerminalListRetryAttempt() {
    terminalListRetryAttempt += 1;
    return terminalListRetryAttempt;
  }
}
