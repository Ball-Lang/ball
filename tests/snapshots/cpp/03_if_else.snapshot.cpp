
namespace {


} // namespace

int main() {
    auto x = BallDyn(static_cast<int64_t>(5));
    if ((x > static_cast<int64_t>(0))) {
        std::cout << ball_to_string("positive"s) << std::endl;
    } else {
        if ((x < static_cast<int64_t>(0))) {
            std::cout << ball_to_string("negative"s) << std::endl;
        } else {
            std::cout << ball_to_string("zero"s) << std::endl;
        }
    }
    return 0;
}
