const OsDetect = {
  mounted() {
    const platform = navigator.platform || ""
    const userAgent = navigator.userAgent || ""
    this.pushEvent("os_detected", { platform, user_agent: userAgent })
  }
}

export default OsDetect
