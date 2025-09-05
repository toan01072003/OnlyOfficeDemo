
namespace OnlyOfficeDemo.Models
{
    public class OnlyOfficeConfig
    {
        public string DocumentServerApiJs { get; set; }
        public object Config { get; set; }
    }

    public class OnlineViewerModel
    {
        public string Title { get; set; }
        public string ViewerUrl { get; set; }
        public string FileUrl { get; set; }
        // iframe | image
        public string Kind { get; set; }
    }
}
