
namespace {


} // namespace

int main() {
    auto i = BallDyn(static_cast<int64_t>(1));
    while ((i <= static_cast<int64_t>(5))) {
        std::cout << ball_to_string(ball_to_string(i)) << std::endl;
        ball_assign(i, (i + static_cast<int64_t>(1)));
    }
    return 0;
}
